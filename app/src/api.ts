import Constants from 'expo-constants';

export type User = { id: string; email: string; displayName: string; createdAt: string };
export type AuthResult = { token: string; user: User };

/** An error the app can show to the user. `field` names the form input it relates to, if any. */
export class ApiError extends Error {
  code: string;
  status: number;
  field?: string;
  constructor(status: number, code: string, message: string, field?: string) {
    super(message);
    this.status = status;
    this.code = code;
    this.field = field;
  }
}

const DEV_SERVER_PORT = 3000;
const TIMEOUT_MS = 10_000;
const API_PREFIX = '/api/v1';

type Extra = { variant?: 'development' | 'staging' | 'production'; apiUrl?: string };
const extra = (Constants.expoConfig?.extra ?? {}) as Extra;

export const appVariant = extra.variant ?? 'development';
export const appVersion = Constants.expoConfig?.version ?? '0.0.0';

/**
 * Where the backend lives (set in app.config.ts at bundle/build time; see docs/devops.md):
 * 1. API_URL, if it was set (always set for staging and production builds).
 * 2. Otherwise (development only): the machine serving the JS bundle, on port 3000.
 */
export function apiBaseUrl(): string {
  if (extra.apiUrl) return extra.apiUrl;
  const hostUri = Constants.expoConfig?.hostUri; // e.g. "10.0.0.78:8081"
  const host = hostUri ? hostUri.replace(/^[a-z]+:\/\//i, '').split('/')[0].replace(/:\d+$/, '') : '';
  return `http://${host || 'localhost'}:${DEV_SERVER_PORT}`;
}

// Notified when the server says this app version is too old (426 UPGRADE_REQUIRED).
let upgradeListener: (() => void) | undefined;
export function onUpgradeRequired(listener: (() => void) | undefined) {
  upgradeListener = listener;
}

async function request<T>(method: string, path: string, opts: { body?: object; token?: string } = {}): Promise<T> {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), TIMEOUT_MS);
  let res: Response;
  try {
    res = await fetch(apiBaseUrl() + API_PREFIX + path, {
      method,
      headers: {
        'X-App-Version': appVersion,
        ...(opts.body && { 'Content-Type': 'application/json' }),
        ...(opts.token && { Authorization: `Bearer ${opts.token}` }),
      },
      body: opts.body ? JSON.stringify(opts.body) : undefined,
      signal: controller.signal,
    });
  } catch {
    throw new ApiError(0, 'NETWORK', "Can't reach the server. Check your connection and try again.");
  } finally {
    clearTimeout(timer);
  }
  if (res.status === 204) return undefined as T;
  const data = await res.json().catch(() => null);
  if (!res.ok) {
    const e = data?.error;
    if (e?.code === 'UPGRADE_REQUIRED') upgradeListener?.();
    throw new ApiError(
      res.status,
      e?.code ?? 'INTERNAL',
      e?.message ?? 'Something went wrong. Please try again.',
      e?.field,
    );
  }
  return data as T;
}

export const api = {
  signup: (displayName: string, email: string, password: string) =>
    request<AuthResult>('POST', '/auth/signup', { body: { displayName, email, password } }),
  login: (email: string, password: string) =>
    request<AuthResult>('POST', '/auth/login', { body: { email, password } }),
  logout: (token: string) => request<void>('POST', '/auth/logout', { token }),
  me: (token: string) => request<{ user: User }>('GET', '/me', { token }),
};
