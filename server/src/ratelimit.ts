import { createHash } from 'node:crypto';
import { Valkey } from 'iovalkey';

/** A fixed-window limit: at most `max` counted events per `windowMs`. */
export type Limit = { max: number; windowMs: number };

export type Limits = {
  /** Every login request from one client network. */
  loginPerClient: Limit;
  /** Failed logins for one email from one client network. Cleared by a successful login. */
  loginFailuresPerClientEmail: Limit;
  /** Every signup request from one client network. */
  signupPerClient: Limit;
};

const MINUTE = 60_000;
export const DEFAULT_LIMITS: Limits = {
  loginPerClient: { max: 100, windowMs: 15 * MINUTE },
  loginFailuresPerClientEmail: { max: 5, windowMs: 15 * MINUTE },
  signupPerClient: { max: 20, windowMs: 60 * MINUTE },
};

/** A counter's state. `resetMs` is how long until its window ends (0 if there is no window). */
export type Count = { count: number; resetMs: number };

/**
 * Where counters live. Each key is a counter with its own fixed window, which starts at the
 * key's first hit and lasts `windowMs`. After it ends, the key starts again from zero.
 */
export interface RateLimitStore {
  /** Adds one to the key, starting a new window if there isn't one, and returns the new state. */
  hit(key: string, windowMs: number): Promise<Count>;
  /** Returns the key's state without changing it. */
  peek(key: string): Promise<Count>;
  /** Deletes the key. */
  reset(key: string): Promise<void>;
  close(): Promise<void>;
}

/**
 * Counters in this process's memory. For development and tests only: every server process
 * has its own counters, and they're lost on restart.
 */
export class MemoryRateLimitStore implements RateLimitStore {
  #entries = new Map<string, { count: number; resetAt: number }>();
  #hits = 0;
  #now: () => number;

  /** `now` is injectable so tests can move the clock. */
  constructor(now: () => number = Date.now) {
    this.#now = now;
  }

  #live(key: string, t: number) {
    const e = this.#entries.get(key);
    if (e && e.resetAt <= t) {
      this.#entries.delete(key);
      return undefined;
    }
    return e;
  }

  async hit(key: string, windowMs: number): Promise<Count> {
    const t = this.#now();
    if (++this.#hits % 1000 === 0) {
      for (const [k, e] of this.#entries) if (e.resetAt <= t) this.#entries.delete(k);
    }
    let e = this.#live(key, t);
    if (!e) {
      e = { count: 0, resetAt: t + windowMs };
      this.#entries.set(key, e);
    }
    e.count++;
    return { count: e.count, resetMs: e.resetAt - t };
  }

  async peek(key: string): Promise<Count> {
    const t = this.#now();
    const e = this.#live(key, t);
    return e ? { count: e.count, resetMs: e.resetAt - t } : { count: 0, resetMs: 0 };
  }

  async reset(key: string): Promise<void> {
    this.#entries.delete(key);
  }

  async close(): Promise<void> {
    this.#entries.clear();
  }
}

// INCR and the expiry must happen together, or a crash between them could leave a counter
// that never expires. A Lua script runs atomically in Valkey. A negative PTTL means the key
// has no expiry yet (it was just created).
const HIT_SCRIPT = `
local c = redis.call('INCR', KEYS[1])
local t = redis.call('PTTL', KEYS[1])
if t < 0 then
  redis.call('PEXPIRE', KEYS[1], ARGV[1])
  t = tonumber(ARGV[1])
end
return {c, t}
`;

/** Counters in Valkey, shared by every server process that uses the same Valkey database. */
export class ValkeyRateLimitStore implements RateLimitStore {
  #client: Valkey;

  /** `url` is e.g. `redis://localhost:6379/0`. The last part picks the Valkey database. */
  constructor(url: string) {
    this.#client = new Valkey(url, {
      // Fail fast while Valkey is unreachable, instead of queueing commands and making
      // logins hang. The limiter lets requests through when the store fails.
      enableOfflineQueue: false,
      maxRetriesPerRequest: 1,
      commandTimeout: 500,
    });
    // Without a listener, connection errors would be thrown as unhandled 'error' events.
    // The limiter logs each failed command, so these can be ignored here.
    this.#client.on('error', () => {});
  }

  /**
   * Waits until the connection is up. Commands sent before then fail (and the limiter lets
   * those requests through), so call this before serving requests.
   */
  ready(timeoutMs = 5000): Promise<void> {
    if (this.#client.status === 'ready') return Promise.resolve();
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.#client.off('ready', onReady);
        reject(new Error(`Valkey not ready after ${timeoutMs} ms`));
      }, timeoutMs);
      const onReady = () => {
        clearTimeout(timer);
        resolve();
      };
      this.#client.once('ready', onReady);
    });
  }

  async hit(key: string, windowMs: number): Promise<Count> {
    const [count, resetMs] = (await this.#client.eval(HIT_SCRIPT, 1, key, windowMs)) as [
      number,
      number,
    ];
    return { count, resetMs };
  }

  async peek(key: string): Promise<Count> {
    const results = await this.#client.multi().get(key).pttl(key).exec();
    if (!results) throw new Error('Valkey transaction was aborted');
    for (const [err] of results) if (err) throw err;
    const count = Number(results[0][1] ?? 0);
    const ttl = Number(results[1][1]);
    return { count, resetMs: ttl > 0 ? ttl : 0 };
  }

  async reset(key: string): Promise<void> {
    await this.#client.del(key);
  }

  async close(): Promise<void> {
    await this.#client.quit().catch(() => this.#client.disconnect());
  }
}

/**
 * Applies limits on top of a store. If the store fails, for example because Valkey is down,
 * requests are allowed and the error is reported through `onError`. An outage of the
 * limiter shouldn't stop people from logging in.
 */
export class RateLimiter {
  #store: RateLimitStore;
  #onError: (err: unknown) => void;

  constructor(store: RateLimitStore, onError: (err: unknown) => void) {
    this.#store = store;
    this.#onError = onError;
  }

  /** Counts one event. Returns the time until the window ends if this event is over the limit. */
  async hit(key: string, limit: Limit): Promise<number | undefined> {
    try {
      const c = await this.#store.hit(key, limit.windowMs);
      return c.count > limit.max ? c.resetMs : undefined;
    } catch (err) {
      this.#onError(err);
      return undefined;
    }
  }

  /** Without counting anything: returns the time until the window ends if the limit is already reached. */
  async blocked(key: string, limit: Limit): Promise<number | undefined> {
    try {
      const c = await this.#store.peek(key);
      return c.count >= limit.max ? c.resetMs : undefined;
    } catch (err) {
      this.#onError(err);
      return undefined;
    }
  }

  async reset(key: string): Promise<void> {
    try {
      await this.#store.reset(key);
    } catch (err) {
      this.#onError(err);
    }
  }

  close(): Promise<void> {
    return this.#store.close();
  }
}

/**
 * The part of a client IP address that limits are counted against.
 * - IPv4: the whole address.
 * - IPv4-mapped IPv6 (`::ffff:1.2.3.4`): the IPv4 address, so both forms count together.
 * - IPv6: the /64 network. One device or home network usually gets a whole /64, so counting
 *   single IPv6 addresses would let one client spread its attempts over millions of addresses.
 */
export function clientKey(ip: string): string {
  const mapped = /^::ffff:(\d+\.\d+\.\d+\.\d+)$/i.exec(ip);
  if (mapped) return mapped[1];
  if (!ip.includes(':')) return ip;

  const addr = ip.split('%')[0].toLowerCase(); // drop any zone ID, e.g. "fe80::1%eth0"
  const [headStr, tailStr] = addr.split('::');
  const parts = (s: string | undefined) =>
    // A trailing embedded IPv4 address, e.g. "64:ff9b::1.2.3.4", fills two 16-bit groups.
    s ? s.split(':').flatMap((p) => (p.includes('.') ? ['0', '0'] : [p])) : [];
  const head = parts(headStr);
  const tail = tailStr === undefined ? [] : parts(tailStr);
  const groups = [...head, ...Array(Math.max(0, 8 - head.length - tail.length)).fill('0'), ...tail];
  const prefix = groups.slice(0, 4).map((g) => parseInt(g, 16).toString(16));
  return `${prefix.join(':')}::/64`;
}

/**
 * Hashes an email for use in a key, so that Valkey doesn't hold email addresses and keys stay short.
 * Rate-limit keys aren't secret; this is only to keep personal data out of the shared store.
 */
export function emailKey(email: string): string {
  return createHash('sha256').update(email).digest('hex').slice(0, 32);
}

/** "1 minute", "15 minutes": rounded up, never less than 1. */
export function waitText(resetMs: number): string {
  const min = Math.max(1, Math.ceil(resetMs / MINUTE));
  return min === 1 ? '1 minute' : `${min} minutes`;
}
