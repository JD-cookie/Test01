import Fastify, { type FastifyReply, type FastifyRequest } from 'fastify';
import cors from '@fastify/cors';
import { randomUUID } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { openDb, type Db } from './db.ts';
import {
  getDummyHash,
  hashPassword,
  hashToken,
  newSessionToken,
  verifyPassword,
} from './crypto.ts';
import {
  clientKey,
  DEFAULT_LIMITS,
  emailKey,
  MemoryRateLimitStore,
  RateLimiter,
  waitText,
  type Limits,
  type RateLimitStore,
} from './ratelimit.ts';

export const SESSION_TTL_DAYS = 30;
export const PASSWORD_MIN = 8;
export const PASSWORD_MAX = 128;
export const DISPLAY_NAME_MAX = 50;
export const EMAIL_MAX = 254;
const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

/** Bump only for breaking API changes; serve the old version alongside until old apps are gone. */
export const API_VERSION = 1;
const API = `/api/v${API_VERSION}`;
export const SERVER_VERSION: string = JSON.parse(
  readFileSync(new URL('../package.json', import.meta.url), 'utf8'),
).version;

/** Compares dotted numeric versions ("1.2.10" > "1.2.9"). Missing parts count as 0. */
export function compareVersions(a: string, b: string): number {
  const pa = a.split('.').map((n) => parseInt(n, 10) || 0);
  const pb = b.split('.').map((n) => parseInt(n, 10) || 0);
  for (let i = 0; i < Math.max(pa.length, pb.length); i++) {
    const d = (pa[i] ?? 0) - (pb[i] ?? 0);
    if (d) return Math.sign(d);
  }
  return 0;
}

type UserRow = {
  id: string;
  email: string;
  display_name: string;
  password_hash: string;
  created_at: string;
};

type PublicUser = { id: string; email: string; displayName: string; createdAt: string };

class ApiError extends Error {
  statusCode: number;
  code: string;
  field?: string;
  headers?: Record<string, string>;
  constructor(statusCode: number, code: string, message: string, field?: string) {
    super(message);
    this.statusCode = statusCode;
    this.code = code;
    this.field = field;
  }
}

function rateLimited(resetMs: number): ApiError {
  const err = new ApiError(
    429,
    'RATE_LIMITED',
    `Too many attempts. Please wait ${waitText(resetMs)} and try again.`,
  );
  err.headers = { 'retry-after': String(Math.max(1, Math.ceil(resetMs / 1000))) };
  return err;
}

function toPublic(u: UserRow): PublicUser {
  return { id: u.id, email: u.email, displayName: u.display_name, createdAt: u.created_at };
}

function str(body: unknown, key: string): string {
  const v = (body as Record<string, unknown> | null)?.[key];
  return typeof v === 'string' ? v : '';
}

export function normalizeEmail(raw: string): string {
  return raw.trim().toLowerCase();
}

function validateEmail(email: string): void {
  if (!email) throw new ApiError(400, 'VALIDATION_ERROR', 'Email is required.', 'email');
  if (email.length > EMAIL_MAX || !EMAIL_RE.test(email))
    throw new ApiError(400, 'VALIDATION_ERROR', 'Enter a valid email address.', 'email');
}

function validatePassword(pw: string): void {
  if (pw.length < PASSWORD_MIN)
    throw new ApiError(
      400,
      'VALIDATION_ERROR',
      `Password must be at least ${PASSWORD_MIN} characters.`,
      'password',
    );
  if (pw.length > PASSWORD_MAX)
    throw new ApiError(
      400,
      'VALIDATION_ERROR',
      `Password must be at most ${PASSWORD_MAX} characters.`,
      'password',
    );
}

function validateDisplayName(name: string): void {
  if (!name) throw new ApiError(400, 'VALIDATION_ERROR', 'Name is required.', 'displayName');
  if (name.length > DISPLAY_NAME_MAX)
    throw new ApiError(
      400,
      'VALIDATION_ERROR',
      `Name must be at most ${DISPLAY_NAME_MAX} characters.`,
      'displayName',
    );
}

function createSession(db: Db, userId: string): string {
  const token = newSessionToken();
  const now = new Date();
  const expires = new Date(now.getTime() + SESSION_TTL_DAYS * 24 * 60 * 60 * 1000);
  db.prepare(
    'INSERT INTO sessions (token_hash, user_id, created_at, expires_at) VALUES (?, ?, ?, ?)',
  ).run(hashToken(token), userId, now.toISOString(), expires.toISOString());
  return token;
}

function bearerToken(req: FastifyRequest): string | undefined {
  const h = req.headers.authorization;
  if (!h?.startsWith('Bearer ')) return undefined;
  return h.slice('Bearer '.length).trim() || undefined;
}

export type AppOptions = {
  dbPath: string;
  logger?: boolean;
  minAppVersion?: string;
  /** Where rate-limit counters live. Defaults to this process's memory. */
  rateLimitStore?: RateLimitStore;
  /** Overrides for individual limits, mainly for tests. */
  limits?: Partial<Limits>;
  /**
   * Which proxies to trust for the client address in `X-Forwarded-For`, passed to Fastify's
   * `trustProxy`. Leave it off unless the server sits behind a proxy you control: otherwise
   * clients could set the header themselves and dodge per-client limits.
   */
  trustProxy?: boolean | string;
};

export function buildApp(opts: AppOptions) {
  const minAppVersion = opts.minAppVersion ?? '0.0.0';
  const limits: Limits = { ...DEFAULT_LIMITS, ...opts.limits };
  const db = openDb(opts.dbPath);
  const app = Fastify({ logger: opts.logger ?? false, trustProxy: opts.trustProxy ?? false });
  const limiter = new RateLimiter(opts.rateLimitStore ?? new MemoryRateLimitStore(), (err) =>
    app.log.error({ err }, 'rate limit store failed; allowing the request'),
  );
  app.register(cors, { origin: true });
  app.addHook('onClose', async () => {
    db.close();
    await limiter.close();
  });

  app.setErrorHandler((err: Error & { statusCode?: number }, _req, reply) => {
    if (err instanceof ApiError) {
      if (err.headers) reply.headers(err.headers);
      return reply.status(err.statusCode).send({
        error: { code: err.code, message: err.message, ...(err.field && { field: err.field }) },
      });
    }
    if (err.statusCode && err.statusCode < 500) {
      return reply
        .status(err.statusCode)
        .send({ error: { code: 'BAD_REQUEST', message: 'The request was malformed.' } });
    }
    app.log.error(err);
    return reply
      .status(500)
      .send({ error: { code: 'INTERNAL', message: 'Something went wrong. Please try again.' } });
  });

  app.setNotFoundHandler((_req, reply) =>
    reply.status(404).send({ error: { code: 'NOT_FOUND', message: 'Not found.' } }),
  );

  /** Resolves the bearer token to a user, or throws 401. */
  function requireUser(req: FastifyRequest): UserRow {
    const token = bearerToken(req);
    if (token) {
      const row = db
        .prepare(
          `SELECT u.* FROM sessions s JOIN users u ON u.id = s.user_id
           WHERE s.token_hash = ? AND s.expires_at > ?`,
        )
        .get(hashToken(token), new Date().toISOString()) as UserRow | undefined;
      if (row) return row;
    }
    throw new ApiError(401, 'UNAUTHENTICATED', 'Your session has expired. Please log in again.');
  }

  // Apps older than MIN_APP_VERSION are told to update. Requests without the header
  // (curl, monitoring) are let through. /meta is exempt so any app can read the requirement.
  app.addHook('onRequest', async (req) => {
    if (!req.url.startsWith(`${API}/`) || req.url.startsWith(`${API}/meta`)) return;
    const appVersion = req.headers['x-app-version'];
    if (typeof appVersion === 'string' && compareVersions(appVersion, minAppVersion) < 0)
      throw new ApiError(
        426,
        'UPGRADE_REQUIRED',
        'A newer version of the app is required. Please install the latest version.',
      );
  });

  app.get('/api/health', async () => ({ status: 'ok' }));

  app.get(`${API}/meta`, async () => ({
    apiVersion: API_VERSION,
    serverVersion: SERVER_VERSION,
    minAppVersion,
  }));

  app.post(`${API}/auth/signup`, async (req, reply: FastifyReply) => {
    const wait = await limiter.hit(`rl:signup:client:${clientKey(req.ip)}`, limits.signupPerClient);
    if (wait !== undefined) throw rateLimited(wait);

    const email = normalizeEmail(str(req.body, 'email'));
    const password = str(req.body, 'password');
    const displayName = str(req.body, 'displayName').trim();
    validateDisplayName(displayName);
    validateEmail(email);
    validatePassword(password);

    if (db.prepare('SELECT 1 FROM users WHERE email = ?').get(email))
      throw new ApiError(409, 'EMAIL_TAKEN', 'An account with this email already exists.', 'email');

    const user: UserRow = {
      id: randomUUID(),
      email,
      display_name: displayName,
      password_hash: await hashPassword(password),
      created_at: new Date().toISOString(),
    };
    try {
      db.prepare(
        'INSERT INTO users (id, email, display_name, password_hash, created_at) VALUES (?, ?, ?, ?, ?)',
      ).run(user.id, user.email, user.display_name, user.password_hash, user.created_at);
    } catch (err) {
      // Lost a race with a concurrent signup for the same email.
      if (String(err).includes('UNIQUE'))
        throw new ApiError(409, 'EMAIL_TAKEN', 'An account with this email already exists.', 'email');
      throw err;
    }
    const token = createSession(db, user.id);
    return reply.status(201).send({ token, user: toPublic(user) });
  });

  app.post(`${API}/auth/login`, async (req) => {
    const client = clientKey(req.ip);
    let wait = await limiter.hit(`rl:login:client:${client}`, limits.loginPerClient);
    if (wait !== undefined) throw rateLimited(wait);

    const email = normalizeEmail(str(req.body, 'email'));
    const password = str(req.body, 'password');
    // Checked before the password, so a blocked client can't keep guessing. This applies
    // even to the right password, otherwise the response would reveal which guess was right.
    const failuresKey = `rl:login:fail:${client}:${emailKey(email)}`;
    wait = await limiter.blocked(failuresKey, limits.loginFailuresPerClientEmail);
    if (wait !== undefined) throw rateLimited(wait);

    const user = db.prepare('SELECT * FROM users WHERE email = ?').get(email) as
      | UserRow
      | undefined;
    const ok = await verifyPassword(password, user?.password_hash ?? (await getDummyHash()));
    if (!user || !ok) {
      await limiter.hit(failuresKey, limits.loginFailuresPerClientEmail);
      throw new ApiError(401, 'INVALID_CREDENTIALS', 'Incorrect email or password.');
    }
    await limiter.reset(failuresKey);
    return { token: createSession(db, user.id), user: toPublic(user) };
  });

  app.post(`${API}/auth/logout`, async (req, reply) => {
    const token = bearerToken(req);
    if (token) db.prepare('DELETE FROM sessions WHERE token_hash = ?').run(hashToken(token));
    return reply.status(204).send();
  });

  app.get(`${API}/me`, async (req) => ({ user: toPublic(requireUser(req)) }));

  return app;
}
