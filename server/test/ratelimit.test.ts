import { test, describe } from 'node:test';
import assert from 'node:assert/strict';
import { buildApp, type AppOptions } from '../src/app.ts';
import {
  clientKey,
  MemoryRateLimitStore,
  ValkeyRateLimitStore,
  waitText,
  type RateLimitStore,
} from '../src/ratelimit.ts';

const MINUTE = 60_000;
const alice = { email: 'alice@example.com', password: 'correct horse', displayName: 'Alice' };
const wrong = { email: alice.email, password: 'wrong password' };

/** An app with a controllable clock. `ip` sets the client address for each request. */
async function setup(opts: Partial<AppOptions> = {}) {
  let now = 1_000_000;
  const clock = { advance: (ms: number) => (now += ms) };
  const app = buildApp({
    dbPath: ':memory:',
    rateLimitStore: new MemoryRateLimitStore(() => now),
    ...opts,
  });
  const post = (path: string, body: object, ip = '203.0.113.7') =>
    app.inject({ method: 'POST', url: `/api/v1/auth/${path}`, payload: body, remoteAddress: ip });
  const login = (body: object, ip?: string) => post('login', body, ip);
  const signup = (body: object, ip?: string) => post('signup', body, ip);
  await signup(alice, '198.51.100.1'); // from another network, so it doesn't use up the test's counts
  return { app, clock, login, signup };
}

function assertLimited(res: { statusCode: number; json(): any; headers: Record<string, unknown> }) {
  assert.equal(res.statusCode, 429);
  assert.equal(res.json().error.code, 'RATE_LIMITED');
  assert.match(res.json().error.message, /^Too many attempts\. Please wait \d+ minutes? and try again\.$/);
  assert.equal('field' in res.json().error, false);
  assert.ok(Number(res.headers['retry-after']) >= 1);
}

describe('login failures per client and email', () => {
  test('the 6th attempt after 5 failures is refused, even with the right password', async () => {
    const { app, login } = await setup();
    try {
      for (let i = 0; i < 5; i++) assert.equal((await login(wrong)).statusCode, 401);
      const blocked = await login(alice);
      assertLimited(blocked);
      assert.equal(blocked.json().error.message, 'Too many attempts. Please wait 15 minutes and try again.');
      assert.equal(blocked.headers['retry-after'], '900');
    } finally {
      await app.close();
    }
  });

  test('a burst of parallel guesses gets no more than 5 password checks', async () => {
    const { app, login } = await setup();
    try {
      const results = await Promise.all(Array.from({ length: 20 }, () => login(wrong)));
      const codes = results.map((r) => r.statusCode);
      assert.equal(codes.filter((c) => c === 401).length, 5);
      assert.equal(codes.filter((c) => c === 429).length, 15);
      assertLimited(await login(alice));
    } finally {
      await app.close();
    }
  });

  test('other emails from the same client, and the same email from other clients, still work', async () => {
    const { app, login, signup } = await setup();
    try {
      await signup({ ...alice, email: 'bob@example.com' }, '198.51.100.1');
      for (let i = 0; i < 5; i++) await login(wrong);
      assert.equal((await login({ ...alice, email: 'bob@example.com' })).statusCode, 200);
      assert.equal((await login(alice, '192.0.2.50')).statusCode, 200);
    } finally {
      await app.close();
    }
  });

  test('email case and spacing don\'t give extra attempts', async () => {
    const { app, login } = await setup();
    try {
      for (const email of ['alice@example.com', 'ALICE@example.com', ' Alice@Example.com', 'alice@EXAMPLE.com', 'aLiCe@example.com'])
        assert.equal((await login({ ...wrong, email })).statusCode, 401);
      assertLimited(await login(alice));
    } finally {
      await app.close();
    }
  });

  test('a successful login clears the failure count', async () => {
    const { app, login } = await setup();
    try {
      for (let i = 0; i < 4; i++) await login(wrong);
      assert.equal((await login(alice)).statusCode, 200);
      for (let i = 0; i < 4; i++) assert.equal((await login(wrong)).statusCode, 401);
      assert.equal((await login(alice)).statusCode, 200);
    } finally {
      await app.close();
    }
  });

  test('the block lifts when the window ends', async () => {
    const { app, clock, login } = await setup();
    try {
      for (let i = 0; i < 5; i++) await login(wrong);
      clock.advance(10 * MINUTE);
      const blocked = await login(alice);
      assertLimited(blocked);
      assert.equal(blocked.json().error.message, 'Too many attempts. Please wait 5 minutes and try again.');
      clock.advance(5 * MINUTE);
      assert.equal((await login(alice)).statusCode, 200);
    } finally {
      await app.close();
    }
  });

  test('addresses in one IPv6 /64 share a count; IPv4-mapped addresses count as IPv4', async () => {
    const { app, login } = await setup();
    try {
      for (let i = 0; i < 5; i++) await login(wrong, `2001:db8:1:2::${i + 1}`);
      assertLimited(await login(alice, '2001:db8:1:2:ffff:ffff:ffff:ffff'));
      assert.equal((await login(alice, '2001:db8:1:3::1')).statusCode, 200);

      for (let i = 0; i < 5; i++) await login(wrong, i % 2 ? '192.0.2.9' : '::ffff:192.0.2.9');
      assertLimited(await login(alice, '192.0.2.9'));
    } finally {
      await app.close();
    }
  });
});

test('login requests per client are capped, whatever the outcome', async () => {
  const { app, login } = await setup({ limits: { loginPerClient: { max: 3, windowMs: 15 * MINUTE } } });
  try {
    for (let i = 0; i < 3; i++) assert.equal((await login(alice)).statusCode, 200);
    assertLimited(await login(alice));
    assert.equal((await login(alice, '192.0.2.50')).statusCode, 200);
  } finally {
    await app.close();
  }
});

test('signup requests per client are capped, counting rejected ones', async () => {
  const { app, clock, signup } = await setup({ limits: { signupPerClient: { max: 2, windowMs: 60 * MINUTE } } });
  try {
    assert.equal((await signup({ ...alice, email: 'not-an-email' })).statusCode, 400);
    assert.equal((await signup({ ...alice, email: 'carol@example.com' })).statusCode, 201);
    assertLimited(await signup({ ...alice, email: 'dave@example.com' }));
    assert.equal((await signup({ ...alice, email: 'dave@example.com' }, '192.0.2.50')).statusCode, 201);
    clock.advance(60 * MINUTE);
    assert.equal((await signup({ ...alice, email: 'erin@example.com' })).statusCode, 201);
  } finally {
    await app.close();
  }
});

test('X-Forwarded-For is ignored unless a proxy is trusted', async () => {
  const limits = { loginPerClient: { max: 1, windowMs: 15 * MINUTE } };
  const send = (app: ReturnType<typeof buildApp>, forwardedFor: string) =>
    app.inject({
      method: 'POST',
      url: '/api/v1/auth/login',
      payload: alice,
      remoteAddress: '10.0.0.1',
      headers: { 'x-forwarded-for': forwardedFor },
    });

  const direct = (await setup({ limits })).app;
  try {
    await send(direct, '192.0.2.1');
    assertLimited(await send(direct, '192.0.2.2')); // same socket address, header not trusted
  } finally {
    await direct.close();
  }

  const proxied = (await setup({ limits, trustProxy: '10.0.0.1' })).app;
  try {
    await send(proxied, '192.0.2.1');
    assert.equal((await send(proxied, '192.0.2.2')).statusCode, 200); // a different client
  } finally {
    await proxied.close();
  }
});

test('requests are allowed if the store fails', async () => {
  const broken: RateLimitStore = {
    hit: async () => {
      throw new Error('store down');
    },
    peek: async () => {
      throw new Error('store down');
    },
    reset: async () => {
      throw new Error('store down');
    },
    close: async () => {},
  };
  const app = buildApp({ dbPath: ':memory:', rateLimitStore: broken });
  try {
    const res = await app.inject({ method: 'POST', url: '/api/v1/auth/signup', payload: alice });
    assert.equal(res.statusCode, 201);
    for (let i = 0; i < 7; i++)
      assert.equal(
        (await app.inject({ method: 'POST', url: '/api/v1/auth/login', payload: wrong })).statusCode,
        401,
      );
  } finally {
    await app.close();
  }
});

test('clientKey', () => {
  assert.equal(clientKey('192.0.2.1'), '192.0.2.1');
  assert.equal(clientKey('::ffff:192.0.2.1'), '192.0.2.1');
  assert.equal(clientKey('::FFFF:192.0.2.1'), '192.0.2.1');
  assert.equal(clientKey('2001:db8:1:2:3:4:5:6'), '2001:db8:1:2::/64');
  assert.equal(clientKey('2001:0DB8:0001:0002::7'), '2001:db8:1:2::/64');
  assert.equal(clientKey('2001:db8::1'), '2001:db8:0:0::/64');
  assert.equal(clientKey('::1'), '0:0:0:0::/64');
  assert.equal(clientKey('fe80::1%eth0'), 'fe80:0:0:0::/64');
  assert.equal(clientKey('64:ff9b::192.0.2.1'), '64:ff9b:0:0::/64');
  // Every way of writing an IPv4-mapped address gives the IPv4 address.
  assert.equal(clientKey('::ffff:c000:201'), '192.0.2.1');
  assert.equal(clientKey('::FFFF:C000:0201'), '192.0.2.1');
  assert.equal(clientKey('0:0:0:0:0:ffff:192.0.2.1'), '192.0.2.1');
  assert.equal(clientKey('::ffff:c000:202'), '192.0.2.2');
  // Not an IP address: used as it is.
  assert.equal(clientKey('not-an-ip'), 'not-an-ip');
  assert.equal(clientKey('1:2:3'), '1:2:3');
});

test('waitText', () => {
  assert.equal(waitText(0), '1 minute');
  assert.equal(waitText(1), '1 minute');
  assert.equal(waitText(MINUTE), '1 minute');
  assert.equal(waitText(MINUTE + 1), '2 minutes');
  assert.equal(waitText(15 * MINUTE), '15 minutes');
});

// Runs only when VALKEY_URL points at a Valkey server. It uses keys under "rl:test:".
describe('ValkeyRateLimitStore', { skip: !process.env.VALKEY_URL && 'VALKEY_URL is not set' }, () => {
  test('hit, peek, reset, and expiry', async () => {
    const store = new ValkeyRateLimitStore(process.env.VALKEY_URL!);
    const key = `rl:test:${process.pid}:${Date.now()}`;
    try {
      await store.ready();
      assert.deepEqual(await store.peek(key), { count: 0, resetMs: 0 });
      const first = await store.hit(key, 300);
      assert.equal(first.count, 1);
      assert.ok(first.resetMs > 0 && first.resetMs <= 300);
      assert.equal((await store.hit(key, 300)).count, 2);
      assert.equal((await store.peek(key)).count, 2);
      await store.reset(key);
      assert.equal((await store.peek(key)).count, 0);

      await store.hit(key, 100);
      await new Promise((r) => setTimeout(r, 150));
      assert.equal((await store.peek(key)).count, 0);
      assert.equal((await store.hit(key, 100)).count, 1);
    } finally {
      await store.reset(key).catch(() => {});
      await store.close();
    }
  });

  test('the app works with Valkey', async () => {
    const store = new ValkeyRateLimitStore(process.env.VALKEY_URL!);
    const ip = `192.0.2.${Math.floor(Math.random() * 200) + 1}`;
    const email = `v${Date.now()}@example.com`;
    // The app closes the store when it closes, so build it first and close it in `finally`.
    const app = buildApp({ dbPath: ':memory:', rateLimitStore: store });
    try {
      await store.ready();
      const post = (path: string, body: object) =>
        app.inject({ method: 'POST', url: `/api/v1/auth/${path}`, payload: body, remoteAddress: ip });
      assert.equal((await post('signup', { ...alice, email })).statusCode, 201);
      for (let i = 0; i < 5; i++) assert.equal((await post('login', { email, password: 'nope nope' })).statusCode, 401);
      assertLimited(await post('login', { ...alice, email }));
    } finally {
      await app.close();
    }
  });

  test('fails fast when Valkey is unreachable', async () => {
    const store = new ValkeyRateLimitStore('redis://127.0.0.1:1');
    const started = Date.now();
    try {
      await assert.rejects(store.ready(500));
      await assert.rejects(store.hit('rl:test:unreachable', 1000));
      assert.ok(Date.now() - started < 3000, 'took too long');
    } finally {
      await store.close();
    }
  });
});
