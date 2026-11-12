# Feature 002: Rate limiting of login and signup

Status: implemented. Added 2026-11-12.

## Summary

The server limits how often one client can try to log in or sign up. This slows password guessing against an account, and the bulk creation of accounts, to a pace where neither is practical. It doesn't get in the way of a person who mistypes their password a few times. Counters live in Valkey when it's configured, so every server instance sees the same counts. Without Valkey, which is the case in development and tests, they live in the server process's memory.

## Concepts

| Term | Meaning |
|---|---|
| **Client** | Where a request comes from, for limiting purposes. For IPv4 it's the client's IP address. For IPv6 it's the address's /64 network, because one device or home usually holds a whole /64 and could otherwise use a fresh address for every attempt. An IPv4-mapped IPv6 address (`::ffff:192.0.2.1`) counts as its IPv4 address. |
| **Limit** | At most `max` counted events per window for one key. |
| **Window** | A fixed period that starts at a key's first counted event. When it ends, the key's count goes back to zero. It doesn't slide, and further events don't extend it. |
| **Store** | Where the counters live: Valkey, or process memory. |

## Limits

| Name | Key | Counts | Limit | Applies to |
|---|---|---|---|---|
| Login requests per client | client | every login request, whatever the outcome | 100 per 15 minutes | `POST /api/v1/auth/login` |
| Failed logins per client and email | client + normalized email | failed logins only. A successful login clears it. | 5 per 15 minutes | `POST /api/v1/auth/login` |
| Signup requests per client | client | every signup request, including rejected ones | 20 per hour | `POST /api/v1/auth/signup` |

Why these numbers and keys:
- **Failures are keyed by client and email together,** not by email alone. Keyed by email alone, anyone could lock a real user out of their account by failing on purpose five times. With this key, an attacker locks only themselves out, and the real user can still log in from their own network.
- **The per-client caps are high** because many phones share one public IPv4 address through carrier-grade NAT. A low cap would block innocent users who happen to share an address with someone else. The caps exist to stop one client from spraying guesses across many emails, or from creating accounts in bulk.
- **Signup counts rejected requests too.** Otherwise the "email already taken" response could be used to check emails against the server without limit.

## User-facing behavior

When a limit is hit, the Log in or Create account screen shows the server's message in the red banner above the fields, for example "Too many attempts. Please wait 15 minutes and try again." The message has no `field`, so on Create account it appears in the banner rather than under a field. The fields keep their contents. The app needs no changes for this: it already shows the server's message for any error.

## API

Limited requests get:

```
429 Too Many Requests
Retry-After: 900

{ "error": { "code": "RATE_LIMITED", "message": "Too many attempts. Please wait 15 minutes and try again." } }
```

- The message gives the time until the window ends, rounded up to whole minutes, at least "1 minute". It's singular for 1 minute ("Please wait 1 minute and try again.").
- `Retry-After` gives the same time in whole seconds, rounded up, at least 1.

### Processing order: `POST /api/v1/auth/login`

These steps come before the steps in [001](001-accounts.md#post-apiv1authlogin):

1. Count the request against **login requests per client**. If the count is now over the limit, return `429`.
2. Normalize the email as 001 does. If **failed logins per client and email** has already reached 5, return `429` without checking the password. This holds **even if the password is right**. Otherwise, after a block, a correct guess would get a different response from a wrong one, and guessing could carry on at full speed.
3. Check the email and password as 001 does.
   - On failure, count one failure against **failed logins per client and email**, then return `401 INVALID_CREDENTIALS`. The 5th failure still returns `401`. The 6th attempt gets `429`.
   - On success, clear that client and email's failure count, then continue as 001 does.

Unknown emails are counted like known ones, so the responses still don't reveal which emails have accounts.

### Processing order: `POST /api/v1/auth/signup`

Before step 1 of [001](001-accounts.md#post-apiv1authsignup): count the request against **signup requests per client**. If the count is now over the limit, return `429`.

### Other endpoints

`/api/v1/auth/logout`, `/api/v1/me`, `/api/v1/meta`, and `/api/health` aren't limited.

## Data model

There are no database tables. Each counter is one key in the store, holding an integer count and expiring when its window ends.

| Key | Example |
|---|---|
| `rl:login:client:<client>` | `rl:login:client:203.0.113.7` |
| `rl:login:fail:<client>:<email hash>` | `rl:login:fail:2001:db8:1:2::/64:51b74fd2262cfabb47de57b2cbf6f0e8` |
| `rl:signup:client:<client>` | `rl:signup:client:203.0.113.7` |

- **Email hash:** the first 32 hex characters of the SHA-256 of the normalized email. This keeps email addresses out of the shared store. It isn't meant to keep them secret, since anyone can hash a guessed email.
- **Valkey:** counting is a Lua script that runs `INCR` and then, if the key has no expiry yet, `PEXPIRE`, as one atomic step. A crash can't leave behind a counter that never expires.

## Security

- **Client address:** taken from the TCP connection unless `TRUST_PROXY` is set. If the server sits behind a load balancer or reverse proxy, set `TRUST_PROXY` to that proxy's address so the real client is read from `X-Forwarded-For`. Never set it when clients connect directly, because then they could put any address in the header and get unlimited attempts. When `TRUST_PROXY` is off, `X-Forwarded-For` is ignored.
- **If the store fails** (Valkey down or slow), requests are **allowed** and each failure is logged as an error ("rate limit store failed; allowing the request"). This is fail open: an outage of the limiter shouldn't stop everyone logging in. The Valkey client fails fast: commands time out after 500 ms, and no commands are queued while it's disconnected. At startup, the server waits up to 5 seconds for Valkey. If Valkey is still unreachable, the server starts anyway, logs "limits are off until it connects", and keeps reconnecting in the background.
- **Memory store:** each server process has its own counters, and a restart resets them. It's only suitable while one process serves an environment. Expired entries are swept on every 1000th count, so memory use stays bounded by recent traffic.
- **Known gaps:**
  - A distributed attack on one account, from many networks at once, is slowed only by each network's own limits. Stopping it would need a per-email limit with a challenge, such as a CAPTCHA, rather than a block, because a plain per-email block lets anyone lock users out.
  - There's no allow-list for trusted networks, such as an office NAT.
  - Fixed windows allow a burst at a window boundary: up to 2 × `max` in a short time. This is acceptable at these limits.

## Configuration

| Variable | Default | Effect |
|---|---|---|
| `VALKEY_URL` | unset | Valkey connection URL, e.g. `redis://localhost:6379/0`. The number at the end picks the Valkey database, so environments that share a Valkey server can use different numbers. Unset: counters in process memory. |
| `TRUST_PROXY` | unset (off) | `true` trusts any proxy, which is safe only if nothing can reach the server except through the proxy. Otherwise, a comma-separated list of proxy IPs or CIDRs, e.g. `10.0.0.5` or `10.0.0.0/8`. |

The limits are constants in the code (`DEFAULT_LIMITS` in `server/src/ratelimit.ts`). Tests override them through `buildApp({ limits })`.

To run Valkey locally with podman:

```bash
podman run -d --name test01-valkey -p 127.0.0.1:6379:6379 docker.io/valkey/valkey:9-alpine
VALKEY_URL=redis://127.0.0.1:6379/0 npm run dev
```

## Implementation map (current code)

- `server/src/ratelimit.ts`:
  - `RateLimitStore`, the store interface, with `MemoryRateLimitStore` and `ValkeyRateLimitStore` (using the `iovalkey` client)
  - `RateLimiter`, which applies limits and fails open
  - `clientKey`, which turns an IP address into a client key (IPv6 /64)
  - `emailKey` and `waitText`
  - `DEFAULT_LIMITS`
- `server/src/app.ts`:
  - `rateLimited()`, which builds the 429 error with `Retry-After`
  - the checks at the top of the login and signup handlers
  - `buildApp` options: `rateLimitStore`, `limits`, `trustProxy`
- `server/src/server.ts`: reads `VALKEY_URL` and `TRUST_PROXY`, waits for Valkey at startup, and logs which store is in use.
- Tests: `server/test/ratelimit.test.ts`. They use the memory store with a fake clock. The Valkey tests run only when `VALKEY_URL` is set.

## Acceptance checks

1. Fail to log in as alice 5 times from one client. Each attempt gets `401`. The 6th attempt, even with the right password, gets `429 RATE_LIMITED` with "Too many attempts. Please wait 15 minutes and try again." and `Retry-After: 900`.
2. While the block from check 1 holds: bob can log in from the same client, and alice can log in from a different client.
3. `ALICE@example.com`, ` Alice@Example.com`, and `alice@example.com` all count as one email.
4. 4 failures, a success, then 4 more failures: no `429`.
5. 10 minutes into a block, the message says "5 minutes". After 15 minutes, logging in works again.
6. Failures from `2001:db8:1:2::1` through `2001:db8:1:2::5` block `2001:db8:1:2:ffff:ffff:ffff:ffff`, but not `2001:db8:1:3::1`. `::ffff:192.0.2.9` and `192.0.2.9` count as the same client.
7. With a cap of 3 login requests per client, the 4th request gets `429`, even after 3 successful logins. Other clients are unaffected.
8. Signups count rejected requests (`400`) as well as accepted ones. The cap resets when the window ends.
9. Without `TRUST_PROXY`, changing `X-Forwarded-For` doesn't change the client. With `TRUST_PROXY` set to the proxy's address, it does.
10. With the store failing on every call, signup and login behave as if there were no limits.
11. With Valkey: the counts are shared between server processes, and each key expires when its window ends. With Valkey stopped: logins still work, respond quickly, and an error is logged for each request.
