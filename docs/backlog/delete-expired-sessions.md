# Delete expired session rows

Status: **designed**. When the user marks it `ready`, it gets a number and this doc is renamed `NNN-delete-expired-sessions.md`. It moves to `docs/features/` in the PR that builds it.

## Summary

Sessions expire 30 days after login (see [001](../features/001-accounts.md#data-model)), and an expired token is already rejected with `401`. But its row stays in `sessions` forever. This feature deletes expired rows on a schedule, so the table only holds sessions that can still be used. It's housekeeping: nothing changes for users or for the API.

It's for whoever runs the server: today the table only grows, by one row per login, and a lookup by token never needs the old rows. What doesn't change: how long a session lasts, how tokens are checked, logout, and every response the API gives.

### Out of scope

- A setting for the sweep interval, or turning the sweep off. The interval is a constant.
- Logging out a user's other sessions, or limiting how many sessions a user has.
- Coordinating the sweep between instances, or electing one instance to run it. Overlapping sweeps are harmless (see "Processing").
- Running migrations once per deploy, and any database other than SQLite. Both belong to the "Staging/production database and Valkey" backlog item.
- Keeping expired rows for a while for auditing. Nothing reads them today.

## Concepts

- **Sweep:** one `DELETE` of every session whose `expires_at` has passed.

## User-facing behavior

None. Expired sessions already behave as logged out.

## API

No changes. Rejecting an expired token doesn't depend on the sweep: a session with `expires_at` in the past gets `401 UNAUTHENTICATED` ("Your session has expired. Please log in again.", see [001](../features/001-accounts.md)) whether or not its row has been deleted yet.

## Processing

- Each server process sweeps **once at startup**, then **every hour** while it runs:
  ```sql
  DELETE FROM sessions WHERE expires_at <= :now
  ```
  `:now` is the current time as an ISO 8601 UTC string, in the same format as `expires_at` (`Date.prototype.toISOString()`), so comparing the strings compares the times.
- **More than one instance:** every instance runs its own sweep, with no coordination. A sweep is idempotent, so overlapping sweeps are harmless: each deletes whatever is expired at that moment. Nothing is kept in process memory (`AGENTS.md` rule 2).
- **Logging:** a sweep that deletes rows logs `info` with the count (`sessions: deleted N expired`). A sweep that deletes nothing logs nothing. A failed sweep logs `error` and changes nothing else: the server keeps serving, and the next sweep tries again.
- **Shutdown:** the hourly timer stops when the server closes. It doesn't keep the process alive (`unref`).

## Data model

Migration 2 adds an index so the sweep doesn't scan the whole table:

```sql
CREATE INDEX sessions_expires_at ON sessions(expires_at);
```

Append it as a new entry in `MIGRATIONS`, and never edit migration 1. The schema stays portable: a plain index on a text column.

This is the first migration added to a database that already exists, so make the runner in `openDb` safe for two processes starting at once on the same file, for example a dev server restarting while another is still up. Today each process reads `user_version` before its transaction, so both can try to create the index, and the second fails. Instead, for each migration:
1. Start the transaction with `BEGIN IMMEDIATE`, which takes SQLite's write lock at the start, so a second process waits instead of failing. Also set `PRAGMA busy_timeout` (5 seconds) when the database opens, so the wait doesn't fail at once.
2. Read `user_version` again inside the transaction, and skip the migration if another process already applied it.

Probed on 2026-11-18 (Node 24.22, a scratch file database at version 1, two child processes migrating it while the parent held the write lock, three runs each):
- today's runner: both processes failed with `database is locked`
- `busy_timeout` alone, without the recheck: one failed with `index sessions_expires_at already exists`
- `BEGIN IMMEDIATE`, the recheck, and `busy_timeout`: both succeeded, at version 2

Without the parent holding the lock, today's runner still failed 3 times out of 3, but which way depends on timing. So acceptance check 8 holds the lock, which makes the overlap certain.

This only covers SQLite. The server still supports one instance per database ([devops.md](../devops.md#environments)). Running migrations once per deploy, instead of at each instance's startup, belongs to the staging and production database item in the backlog.

## Security and configuration

- Nobody can trigger a sweep: there's no endpoint, and it runs only on the server's own timer.
- If the database is busy or fails, the sweep logs `error` and the server keeps serving. Expired rows wait for the next sweep, and expired tokens are still rejected meanwhile.
- No new settings. The interval (1 hour) is a constant. Tests call the sweep function directly instead of waiting for the timer.
- Known gaps: none new. The sweep can't delete a row whose session is still valid: it only deletes rows with `expires_at <= now`, the same test login uses to reject a token.
- In 001's Security section, delete the "Deleting expired session rows" line from the known gaps.

## Tasks for the user

None. No settings, secrets, or accounts are needed.

## Implementation map

- `server/src/db.ts`: migration 2 (the index), and the runner's `BEGIN IMMEDIATE` with the `user_version` recheck and the busy timeout.
- `server/src/sessions.ts` (new): `deleteExpiredSessions(db, now): number`, which returns the number of rows deleted, and `SWEEP_INTERVAL_MS` (one hour).
- `server/src/app.ts`: in `buildApp`, the startup sweep, the hourly timer (`setInterval`, then `unref`), and clearing the timer in the existing `onClose` hook, before `db.close()`.
- `server/test/`: tests for the acceptance checks below.

## Acceptance checks

Checks 1 to 7 are `node:test` tests in `server/test/sessions.test.ts`, through `buildApp` and Fastify's `inject` where there's an API to call. Each passes when `npm --prefix server test` reports it passing, in CI too.

1. With one expired and one valid session in the database, `deleteExpiredSessions(db, now)` deletes the expired row, keeps the valid one, and returns 1.
2. A session whose `expires_at` equals `now` is deleted. Its token is already rejected at that moment, because a session is valid only while `expires_at > now`.
3. A sweep with nothing expired deletes nothing and returns 0.
4. **Startup sweep:** an expired row written to a file database before `buildApp` is gone once `await app.ready()` returns.
5. **The sweep doesn't change the API:** a token whose session expired gets `401 UNAUTHENTICATED` from `GET /api/v1/me`, both before and after the sweep deletes its row.
6. **Hourly sweep, stopped by close:** with `mock.timers` (node:test) mocking `setInterval`, and a file database:
   - after startup, an expired row is added through a second connection; `mock.timers.tick` of one hour deletes it
   - after `app.close()`, another expired row is added through the second connection; a tick of one hour leaves it in place
7. **Upgrade:** opening a file database at version 1 (made with migration 1 only) applies migration 2: `PRAGMA user_version` becomes 2, and `sqlite_master` lists the index `sessions_expires_at`.
8. **Two processes migrating at once:** on a file database at version 1, the test takes the write lock with `BEGIN IMMEDIATE` on its own connection, starts two child processes that each call `openDb` on the file, and commits after 500 ms. Both children exit with code 0, and the database is at version 2 with the index. Run against today's runner, both children fail with `database is locked` (see the probe under "Data model"), so this check can fail. It's in `server/test/sessions.test.ts` too, and passes the same way.
9. `npm run check` passes locally and in CI. The 001 doc no longer lists this as a gap, and `docs/devops.md`'s migrations section describes the lock, the recheck, and the busy timeout.

## Decisions made for this ticket

Decided by the user on 2026-11-18, in the refinement:
- **The migration runner's fix is part of this ticket.** Migration 2 is the first one that runs on a database that already exists, so without the fix, two processes starting at once can fail (see "Data model"). It's small, and it ships with the migration that needs it.
- **Sweep at startup, then every hour, with a fixed interval and no setting.** The table grows by one row per login, so an hour is plenty, and a setting would be one more thing to document and test for no gain.
- **Delete rows as soon as they expire, with no grace period.** Nothing reads expired rows: login and `/me` already reject them, and there's no audit log that uses them.
- **The sweep goes in a new `server/src/sessions.ts`,** not in `app.ts`, which is already about 300 lines. `buildApp` only starts and stops it.
