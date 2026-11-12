# Feature 001: Accounts (sign up, log in, stay logged in, log out)

Status: implemented. Added 2026-11-11.

## Summary

A person creates an account with a name, an email, and a password. They then use that email and password to log in on any device. The app keeps them logged in across restarts until they log out or the session expires after 30 days. Logged-out users can see only the Log in and Create account screens. Logged-in users can't see either of those screens.

## Concepts

| Term | Meaning |
|---|---|
| **User** | A person's account. It is identified by a server-generated ID and has a unique email. |
| **Session** | Proof that a device is logged in as a user. It is represented by an opaque **token** that the server issues at signup and login. |
| **Token** | A random secret string. The client sends it on every authenticated request as `Authorization: Bearer <token>`. |

One user can have any number of sessions at once, for example one per phone. Logging out ends only the current device's session.

## User-facing behavior

### App start

1. While the app checks for a saved session, it shows the splash screen (the app icon on a plain background). Nothing else appears during this time.
2. **No saved session:** the app shows **Log in**.
3. **Saved session:** the app shows **Home** right away, using the saved user details. In the background it asks the server for the current user (`GET /api/v1/me`):
   - Success: the app updates the saved user details, in case the name or email changed.
   - `401 UNAUTHENTICATED` (session expired or revoked): the app deletes the saved session and goes to **Log in**.
   - Network failure: the app stays on **Home** with the saved details. This lets the app open offline.
4. If the device storage can't be read, the app treats it as "no saved session".

### Log in screen

- Heading "Test01", with the subtitle "Welcome back. Log in to continue."
- **Email** field: email keyboard, no auto-capitalization, and autofill hints for email.
- **Password** field: masked, with an autofill hint for the current password. Pressing the keyboard's go/enter key submits the form.
- **Log in** button. While a request is running, it shows a spinner and ignores further taps.
- A **New here? Create an account** link replaces this screen with **Create account**.
- Before sending anything, the app checks that both fields have something in them, ignoring whitespace in the email. If either is empty, it shows the banner "Enter your email and password."
- On failure, a red banner above the fields shows the server's message. For bad credentials, that message is "Incorrect email or password." The fields keep their contents.
- On success, the app saves the session and replaces the screen with **Home**. The back button can't return to Log in.

### Create account screen

- Heading "Join Test01", with the subtitle "Create your account."
- Fields, in order:
  - **Name**: max 50 characters, enforced while typing.
  - **Email**.
  - **Password**: placeholder "At least 8 characters".
  - **Confirm password**: pressing go/enter submits the form.
- **Create account** button. It behaves like the Log in button.
- An **Already have an account? Log in** link replaces this screen with **Log in**.
- When the form is submitted, the app checks every field and shows each error in red under its field. The field's border also turns red. The rules, which match the server's, are:

| Field | Rule | Message |
|---|---|---|
| Name | Required after trimming | Name is required. |
| Name | ≤ 50 characters after trimming | Name must be at most 50 characters. |
| Email | Required after trimming | Email is required. |
| Email | Looks like `x@y.z` (no spaces, one `@`, a dot in the domain) and ≤ 254 characters | Enter a valid email address. |
| Password | ≥ 8 characters (spaces count, no trimming) | Password must be at least 8 characters. |
| Password | ≤ 128 characters | Password must be at most 128 characters. |
| Confirm password | Same as Password | Passwords do not match. |

- Editing a field clears that field's error.
- If the server rejects the request with a `field`, the message appears under that field. For example, "An account with this email already exists." appears under Email. Errors without a field appear in the banner.
- On success, the new user is logged in immediately. There's no separate login step, and the app goes to **Home**.

### Home screen (logged in)

- Heading "Hi, <name>!", with the user's email as the subtitle and the text "You're logged in." below.
- **Log out** button. When tapped, the app deletes the saved session from the device, goes straight to **Log in**, and tells the server to revoke the token. That server call is best effort: if it fails, the user is still logged out on the device.

### Network and server errors (all screens)

| Situation | Message shown |
|---|---|
| Server unreachable, or no response within 10 seconds | Can't reach the server. Check your connection and try again. |
| Server error (5xx), or a response the app can't read | Something went wrong. Please try again. |

## Backend API

All paths are under the API version prefix `/api/v1`, except `/api/health`. The base URL depends on the environment, and every request carries an `X-App-Version` header. Both are described in [../devops.md](../devops.md). All request and response bodies are JSON (`Content-Type: application/json`). Every error response has this shape:

```json
{ "error": { "code": "VALIDATION_ERROR", "message": "Human-readable, safe to show.", "field": "email" } }
```

`field` appears only when the error concerns one input. `message` is written for end users. The client shows it as is.

Error codes used by this feature: `VALIDATION_ERROR` (400), `BAD_REQUEST` (400, malformed JSON), `UNAUTHENTICATED` (401), `INVALID_CREDENTIALS` (401), `EMAIL_TAKEN` (409), `INTERNAL` (500). Signup and login can also return `RATE_LIMITED` (429), which is defined in [002-rate-limiting.md](002-rate-limiting.md). Codes shared by every endpoint, `NOT_FOUND` (404) and `UPGRADE_REQUIRED` (426), are defined in [../devops.md](../devops.md).

The **public user** object, which is the only form of a user that leaves the server:

```json
{ "id": "a13ede89-a40b-43fd-bfd8-7241d9b88e8d", "email": "alice@example.com", "displayName": "Alice", "createdAt": "2026-11-11T04:33:24.584Z" }
```

### `GET /api/health`

`200 {"status":"ok"}`. Used to check that the server is up.

### `POST /api/v1/auth/signup`

Request: `{ "displayName": "Alice", "email": "Alice@Example.com", "password": "correct horse" }`

Processing, in this order. First, the rate-limit check from [002](002-rate-limiting.md#processing-order-post-apiv1authsignup).
1. Read each field as a string. A missing field or one that isn't a string counts as `""`.
2. Normalize: trim `displayName`. Trim and lowercase `email`. Leave `password` exactly as sent.
3. Validate in the order name → email → password, using the rules in the table above. Report only the **first** failure: `400 VALIDATION_ERROR` with that `field` and the message from the table.
4. If a user with that normalized email exists, return `409 EMAIL_TAKEN` with `field: "email"` and the message "An account with this email already exists.". This check must also hold when two signups for the same email arrive at the same time, which the database's unique constraint guarantees.
5. Create the user and a session.

Response: `201 { "token": "<token>", "user": <public user> }`

### `POST /api/v1/auth/login`

Request: `{ "email": "alice@example.com", "password": "correct horse" }`

- First, the rate-limit checks from [002](002-rate-limiting.md#processing-order-post-apiv1authlogin). Each attempt is counted there before the password is checked, and a successful login clears the count.
- Normalize the email the same way as signup. Don't validate the format; an email that doesn't match any account just fails.
- If the email is unknown or the password is wrong, return `401 INVALID_CREDENTIALS` with the message "Incorrect email or password.". The response must be identical in both cases, including roughly the same response time: for an unknown email, verify the password against a dummy hash anyway. This stops anyone using login to find out which emails have accounts.
- On success, create a new session. Earlier sessions stay valid.

Response: `200 { "token": "<token>", "user": <public user> }`

### `POST /api/v1/auth/logout`

Header: `Authorization: Bearer <token>`. No body.
Deletes that session if it exists. Always returns `204`, even with a missing, unknown, or already-revoked token, so the call can safely be repeated.

### `GET /api/v1/me`

Header: `Authorization: Bearer <token>`.
`200 { "user": <public user> }` if the token belongs to an unexpired session.
Otherwise `401 UNAUTHENTICATED`, with the message "Your session has expired. Please log in again.".

## Data model

**users**

| Column | Type | Notes |
|---|---|---|
| id | text, PK | Random UUID v4 |
| email | text, unique, not null | Stored normalized (trimmed, lowercase) |
| display_name | text, not null | Trimmed, 1–50 characters |
| password_hash | text, not null | See Security |
| created_at | text, not null | ISO 8601 UTC timestamp |

**sessions**

| Column | Type | Notes |
|---|---|---|
| token_hash | text, PK | SHA-256 hex digest of the token. The raw token is never stored. |
| user_id | text, FK → users.id, on delete cascade | Indexed |
| created_at | text, not null | ISO 8601 UTC |
| expires_at | text, not null | created_at + 30 days. A fixed expiry that is not extended by use. |

## Security

- **Passwords** are hashed with scrypt (N=16384, r=8, p=1, 64-byte key, random 16-byte salt per password). They are stored as `scrypt$16384$8$1$<salt base64>$<key base64>`. Verification recomputes the key with the stored parameters and compares in constant time. Any memory-hard password hash with a per-password salt is an acceptable substitute, such as Argon2id or bcrypt.
- **Tokens** are 32 cryptographically random bytes, encoded as base64url (43 characters). The server stores only their SHA-256 hash, so a leaked database can't be used to impersonate anyone.
- **On the device**, the token and the cached public user are kept in the platform's secure storage: the Android Keystore or the iOS Keychain. They are never kept in plain app storage. Storage keys: `test01.session.token`, `test01.session.user` (JSON).
- **CORS** allows any origin. This is fine for now because there are no browser clients and no cookies are used.
- **Rate limiting** of signup and login is covered by [002-rate-limiting.md](002-rate-limiting.md).
- **Not yet done** (known gaps, each tracked in [../backlog/README.md](../backlog/README.md)):
  - Email verification
  - Password reset
  - HTTPS for development and staging (they use plain HTTP on the local network; production builds require HTTPS, see [../devops.md](../devops.md))
  - Deleting expired session rows (they're already rejected; this is housekeeping only)

## Configuration

This feature has no settings of its own. The settings for the server (`PORT`, `HOST`, `DB_PATH`, `MIN_APP_VERSION`) and for app builds (`APP_VARIANT`, `API_URL`) are in [../devops.md](../devops.md).

## Implementation map (current code)

- Server: `server/src/app.ts` (routes, validation, errors), `server/src/crypto.ts` (hashing and tokens), `server/src/db.ts` (schema and migrations)
- Server tests: `server/test/auth.test.ts`
- App: `app/src/api.ts` (HTTP client, base-URL resolution), `app/src/session.tsx` (session state and persistence), `app/src/app/_layout.tsx` (route guards), `app/src/app/login.tsx`, `app/src/app/signup.tsx`, `app/src/app/(app)/index.tsx` (home)

## Acceptance checks

1. Sign up with `" Alice@Example.com "`. The account's email is `alice@example.com`, and the app lands on Home showing "Hi, Alice!".
2. Sign up again with `ALICE@example.com`. "An account with this email already exists." appears under Email.
3. Close and reopen the app. It opens on Home without asking for a password.
4. Log out. The app shows Log in, and the old token now gets `401` from `/api/v1/me`.
5. Log in with the wrong password, then with an unknown email. Both show exactly "Incorrect email or password."
6. Log in on two devices, then log out on one. The other stays logged in.
7. Stop the server and reopen the app while logged in. It still opens on Home. Logging in while the server is stopped shows the "Can't reach the server…" message.
