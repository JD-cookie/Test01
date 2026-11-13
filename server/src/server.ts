import { buildApp } from './app.ts';
import { ValkeyRateLimitStore } from './ratelimit.ts';

const port = Number(process.env.PORT ?? 3000);
const host = process.env.HOST ?? '0.0.0.0'; // 0.0.0.0 so a phone on the LAN can reach it
const dbPath = process.env.DB_PATH ?? new URL('../data/test01.db', import.meta.url).pathname;

const minAppVersion = process.env.MIN_APP_VERSION ?? '0.0.0';

// Unset: rate-limit counters stay in this process (development). Set it wherever more than one
// server process runs, so they all share the counters.
const valkeyUrl = process.env.VALKEY_URL || undefined;

/** TRUST_PROXY: unset or "false", "true" (trust any proxy), or a comma-separated list of proxy IPs/CIDRs. */
function parseTrustProxy(v: string | undefined): boolean | string {
  if (!v || v === 'false') return false;
  if (v === 'true') return true;
  return v;
}

const valkey = valkeyUrl ? new ValkeyRateLimitStore(valkeyUrl) : undefined;

const app = buildApp({
  dbPath,
  minAppVersion,
  logger: true,
  rateLimitStore: valkey,
  trustProxy: parseTrustProxy(process.env.TRUST_PROXY),
});

if (valkey) {
  try {
    await valkey.ready();
    app.log.info('rate limits: counters in Valkey');
  } catch (err) {
    // Start anyway: the client keeps reconnecting, and requests are allowed until it's back.
    app.log.error({ err }, 'rate limits: Valkey unreachable; limits are off until it connects');
  }
} else {
  app.log.info('rate limits: counters in process memory');
}
await app.listen({ port, host });
