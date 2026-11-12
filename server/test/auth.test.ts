import { test, beforeEach, afterEach } from 'node:test';
import assert from 'node:assert/strict';
import { buildApp } from '../src/app.ts';

let app: ReturnType<typeof buildApp>;
beforeEach(() => {
  app = buildApp({ dbPath: ':memory:' });
});
afterEach(async () => {
  await app.close();
});

const signup = (body: object) => app.inject({ method: 'POST', url: '/api/v1/auth/signup', payload: body });
const login = (body: object) => app.inject({ method: 'POST', url: '/api/v1/auth/login', payload: body });
const me = (token?: string) =>
  app.inject({
    method: 'GET',
    url: '/api/v1/me',
    headers: token ? { authorization: `Bearer ${token}` } : {},
  });

const alice = { email: '  Alice@Example.com ', password: 'correct horse', displayName: ' Alice ' };

test('health', async () => {
  const res = await app.inject({ method: 'GET', url: '/api/health' });
  assert.deepEqual(res.json(), { status: 'ok' });
});

test('signup creates account, normalizes input, returns working token', async () => {
  const res = await signup(alice);
  assert.equal(res.statusCode, 201);
  const body = res.json();
  assert.equal(body.user.email, 'alice@example.com');
  assert.equal(body.user.displayName, 'Alice');
  assert.ok(body.token.length >= 40);
  assert.equal('password_hash' in body.user, false);
  const meRes = await me(body.token);
  assert.equal(meRes.statusCode, 200);
  assert.equal(meRes.json().user.id, body.user.id);
});

test('signup rejects duplicate email case-insensitively', async () => {
  await signup(alice);
  const res = await signup({ ...alice, email: 'ALICE@example.com' });
  assert.equal(res.statusCode, 409);
  assert.equal(res.json().error.code, 'EMAIL_TAKEN');
  assert.equal(res.json().error.field, 'email');
});

test('signup validation', async () => {
  const cases: [object, string][] = [
    [{ ...alice, displayName: '   ' }, 'displayName'],
    [{ ...alice, displayName: 'x'.repeat(51) }, 'displayName'],
    [{ ...alice, email: '' }, 'email'],
    [{ ...alice, email: 'not-an-email' }, 'email'],
    [{ ...alice, password: 'short' }, 'password'],
    [{ ...alice, password: 'x'.repeat(129) }, 'password'],
    [{}, 'displayName'],
  ];
  for (const [body, field] of cases) {
    const res = await signup(body);
    assert.equal(res.statusCode, 400, JSON.stringify(body));
    assert.equal(res.json().error.code, 'VALIDATION_ERROR');
    assert.equal(res.json().error.field, field);
  }
});

test('login succeeds with case-insensitive email, fails generically otherwise', async () => {
  await signup(alice);
  const ok = await login({ email: 'ALICE@EXAMPLE.COM', password: 'correct horse' });
  assert.equal(ok.statusCode, 200);
  assert.ok((await me(ok.json().token)).statusCode === 200);

  for (const body of [
    { email: 'alice@example.com', password: 'wrong password' },
    { email: 'nobody@example.com', password: 'correct horse' },
    {},
  ]) {
    const res = await login(body);
    assert.equal(res.statusCode, 401);
    assert.deepEqual(res.json().error, {
      code: 'INVALID_CREDENTIALS',
      message: 'Incorrect email or password.',
    });
  }
});

test('me requires a valid token', async () => {
  assert.equal((await me()).statusCode, 401);
  assert.equal((await me('garbage')).json().error.code, 'UNAUTHENTICATED');
});

test('logout revokes only that session and is idempotent', async () => {
  const t1 = (await signup(alice)).json().token;
  const t2 = (await login(alice)).json().token;
  const out = await app.inject({
    method: 'POST',
    url: '/api/v1/auth/logout',
    headers: { authorization: `Bearer ${t1}` },
  });
  assert.equal(out.statusCode, 204);
  assert.equal((await me(t1)).statusCode, 401);
  assert.equal((await me(t2)).statusCode, 200);
  const again = await app.inject({
    method: 'POST',
    url: '/api/v1/auth/logout',
    headers: { authorization: `Bearer ${t1}` },
  });
  assert.equal(again.statusCode, 204);
});

test('meta reports versions', async () => {
  const res = await app.inject({ method: 'GET', url: '/api/v1/meta' });
  assert.equal(res.json().apiVersion, 1);
  assert.equal(res.json().minAppVersion, '0.0.0');
  assert.match(res.json().serverVersion, /^\d+\.\d+\.\d+$/);
});

test('apps older than minAppVersion get 426 UPGRADE_REQUIRED', async () => {
  const strict = buildApp({ dbPath: ':memory:', minAppVersion: '1.2.0' });
  const call = (url: string, version?: string) =>
    strict.inject({ method: 'GET', url, headers: version ? { 'x-app-version': version } : {} });
  try {
    const old = await call('/api/v1/me', '1.1.9');
    assert.equal(old.statusCode, 426);
    assert.equal(old.json().error.code, 'UPGRADE_REQUIRED');
    assert.equal((await call('/api/v1/me', '1.2.0')).statusCode, 401); // passes the check
    assert.equal((await call('/api/v1/me', '1.10.0')).statusCode, 401);
    assert.equal((await call('/api/v1/me')).statusCode, 401); // no header: not checked
    assert.equal((await call('/api/v1/meta', '0.1.0')).statusCode, 200); // exempt
    assert.equal((await call('/api/health', '0.1.0')).statusCode, 200); // exempt
  } finally {
    await strict.close();
  }
});

test('unknown paths use the standard error shape', async () => {
  const res = await app.inject({ method: 'POST', url: '/api/auth/login' }); // unversioned path
  assert.equal(res.statusCode, 404);
  assert.deepEqual(res.json(), { error: { code: 'NOT_FOUND', message: 'Not found.' } });
});
