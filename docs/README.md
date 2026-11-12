# Test01 system documentation

Test01 is a learning project: a realistic mobile app and backend for exploring phone apps, GitOps, OpenTelemetry, and other technology (see the [top-level README](../README.md)).

These documents are the **specification** of Test01. Together they hold enough detail to rebuild the system from scratch, in any technology. A rebuilt version needn't look identical, but it should behave the same way, so someone who has used the original would find it familiar.

## Architecture

```
┌──────────────────────┐     HTTP + JSON      ┌───────────────────────┐
│  Mobile app           │  ─────────────────▶  │  Backend API          │
│  (Android now, iOS    │   Bearer token auth  │  (single process)     │
│   later)              │  ◀─────────────────  │                       │
│  Secure storage for   │                      │  Relational database  │
│  the session token    │                      │                       │
└──────────────────────┘                      └───────────────────────┘
```

- **The client** is a single cross-platform mobile app. Its whole state comes from the API, except for the cached session.
- **The server** is a stateless HTTP API with a single relational database: SQLite in development, a database server in staging and production. State shared between server instances goes in Valkey, never in process memory. See [devops.md](devops.md#environments). Every rule is enforced on the server. The client repeats some checks only to give quicker feedback.
- **API conventions**, which every feature follows:
  - Paths start with `/api/v1/`. The version only changes for breaking changes; see [devops.md](devops.md).
  - Every request from the app sends `X-App-Version`. Apps older than the server's minimum get `426 UPGRADE_REQUIRED`.
  - Bodies are JSON.
  - Authenticated requests send `Authorization: Bearer <token>`.
  - Errors look like `{"error":{"code","message","field?"}}`, where `message` is safe to show to users and `field` names the form input it concerns.
  - Timestamps are ISO 8601 UTC strings, and IDs are UUIDs.
  - JSON uses camelCase; database columns use snake_case.

## Operations

[devops.md](devops.md) covers the environments (test, development, staging, production), the app and server settings, API versioning and app compatibility, database changes, and how to build and deploy.

## Features

| # | Feature | Status |
|---|---|---|
| 001 | [Accounts: sign up, log in, stay logged in, log out](features/001-accounts.md) | Implemented |
| 002 | [Rate limiting of login and signup](features/002-rate-limiting.md) | Implemented |

Work that isn't built yet, with any design docs written for it, is tracked in [backlog/README.md](backlog/README.md). A design doc moves from `backlog/` into `features/` once it's built, and gets its number then.

## Writing a feature doc

Every feature gets a numbered file in `features/`, written **in the same change** that builds it. Changing a feature means updating its doc in that change too. Each doc covers:

1. **Summary** and **concepts**: what the feature is for and the terms it introduces
2. **User-facing behavior**, screen by screen: what's on each screen, every validation rule and its exact message, loading, empty, and error states, and where each action leads
3. **API**: each endpoint with its request, response, processing order, and error codes
4. **Data model**: tables, columns, constraints
5. **Security and configuration**, plus known gaps
6. **Implementation map**: where the feature lives in the current code. This is the only section tied to the current technology.
7. **Acceptance checks**: concrete scenarios a rebuilt version has to pass
