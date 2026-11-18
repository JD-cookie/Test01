# Delete expired session rows

Status: **ready**, 2026-11-18, as ticket 004. It moves to `docs/features/` in the PR that builds it.

## Summary

Sessions expire 30 days after login (see [001](../features/001-accounts.md#data-model)), and an expired token is already rejected with `401`. But its row stays in `sessions` forever. This feature deletes expired rows on a schedule, so the table only holds sessions that can still be used. It's housekeeping: nothing changes for users or for the API.

It's for whoever runs the server: today every login adds a row, and only a logout deletes one, so expired rows are never removed. A lookup by token never needs them. What doesn't change: how long a session lasts, how tokens are checked, logout, and every response the API gives.

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
- **Logging:** a sweep that deletes rows logs `info` with the count (`sessions: deleted N expired`). A sweep that deletes nothing logs nothing. A failed sweep logs `error` with the error and the message `sessions: sweep failed`, and changes nothing else: the server keeps serving, and the next sweep tries again.
- **Shutdown:** the hourly timer stops when the server closes. It doesn't keep the process alive (`unref`).

## Data model

Migration 2 adds an index so the sweep doesn't scan the whole table:

```sql
CREATE INDEX sessions_expires_at ON sessions(expires_at);
```

Append it as a new entry in `MIGRATIONS`, and never edit migration 1. The schema stays portable: a plain index on a text column.

This is the first migration added to a database that already exists, so make the runner in `openDb` safe for two processes starting at once on the same file, for example a dev server restarting while another is still up. Today each process reads `user_version` before its transaction, so both can try to create the index, and the second fails. Instead, for each migration:
1. Start the transaction with `BEGIN IMMEDIATE`, which takes SQLite's write lock at the start, so a second process waits instead of failing. Set `PRAGMA busy_timeout = 5000` (5 seconds) when the database opens, before the other pragmas, so the wait doesn't fail at once. Set it back to `0` after the migration loop, whether or not a migration ran (on every restart after the upgrade, none does): `node:sqlite` is synchronous, so a busy wait during a request would block the whole server for up to 5 seconds. Requests then fail at once under contention, as they do today, and a sweep that finds the database busy fails, is logged, and runs again an hour later.
2. Read `user_version` again inside the transaction, and skip the migration if another process already applied it.

Probed on 2026-11-18 (Node 24.22, a scratch file database at version 1, two child processes migrating it while the parent held the write lock, three runs each):
- today's runner: both processes failed with `database is locked`
- `busy_timeout` alone, without the recheck: one failed with `index sessions_expires_at already exists`
- `BEGIN IMMEDIATE`, the recheck, and `busy_timeout`: both succeeded, at version 2

A database created without WAL mode can't be used for this: a child's `PRAGMA journal_mode = WAL` then fails at once with `database is locked` while the lock is held, busy timeout or not (probed). Every database `openDb` has opened is already in WAL mode, so only a brand-new file has this problem, and two processes creating the same new file at once stays a known gap.

Without the parent holding the lock, today's runner still failed 3 times out of 3, but which way depends on timing. So acceptance check 9 holds the lock until both children have started: each one writes `start` synchronously just before `openDb`, and then blocks on the lock (probed: the child wrote `start` at 23 ms, the parent committed at 224 ms, the child finished at 252 ms).

This only covers SQLite. The server still supports one instance per database ([devops.md](../devops.md#environments)). Running migrations once per deploy, instead of at each instance's startup, belongs to the staging and production database item in the backlog.

## Security and configuration

- Nobody can trigger a sweep: there's no endpoint, and it runs only on the server's own timer.
- If the database is busy or fails, the sweep logs `error` and the server keeps serving. Expired rows wait for the next sweep, and expired tokens are still rejected meanwhile.
- No new settings. The interval (1 hour) is a constant. Tests call the sweep function directly instead of waiting for the timer.
- Known gaps: two processes creating a brand-new database file at the same moment can still fail, at the WAL pragma (see "Data model"); only one server runs per database for now. The sweep can't delete a row whose session is still valid: it only deletes rows with `expires_at <= now`, the opposite of the test `requireUser` in `server/src/app.ts` uses to accept one (`expires_at > now`), which `GET /api/v1/me` runs.
- In 001's Security section, delete the "Deleting expired session rows" line from the known gaps.

## Tasks for the user

None. No settings, secrets, or accounts are needed.

## Implementation map

- `server/src/db.ts`: migration 2 (the index); export `MIGRATIONS`, so tests can make a version-1 database from migration 1's own SQL instead of a copy; and the runner's `BEGIN IMMEDIATE` with the `user_version` recheck and the busy timeout.
- `server/src/sessions.ts` (new): `deleteExpiredSessions(db, now): number`, which returns the number of rows deleted; `runSweep(db, log)`, which calls it with the current time, logs the result, and catches and logs any error; and `SWEEP_INTERVAL_MS` (one hour).
- `server/src/app.ts`: in `buildApp`, the startup sweep, the hourly timer (`setInterval`, then `unref`), and clearing the timer in the existing `onClose` hook, before `db.close()`.
- `server/test/`: tests for the acceptance checks below.

## Acceptance checks

Checks 1 to 8 are `node:test` tests in `server/test/sessions.test.ts`, through `buildApp` and Fastify's `inject` where there's an API to call. Each passes when `npm --prefix server test` reports it passing, in CI too.

1. With one expired and one valid session in the database, `deleteExpiredSessions(db, now)` deletes the expired row, keeps the valid one, and returns 1.
2. A session whose `expires_at` equals `now` is deleted. (That's safe: its token is already rejected at that moment, because a session is valid only while `expires_at > now`. This part is the reason, not something the test checks.)
3. A sweep with nothing expired deletes nothing and returns 0.
4. **Startup sweep:** an expired row written to a file database before `buildApp` is gone once `await app.ready()` returns. **And it can't stop the server from starting:** on a file database already at version 2, with the test holding the write lock (`BEGIN IMMEDIATE` on its own connection), `buildApp` returns, `await app.ready()` resolves, and `GET /api/health` answers `200` through `inject`. Probed 2026-11-18: under that lock, opening the database works, and the sweep's `DELETE` fails at once with `database is locked`, so the check fails if the startup sweep doesn't go through `runSweep`'s catch.
5. **The sweep doesn't change the API:** on a file database, sign up through the API to get a token, then set its session's `expires_at` to a past time through a second connection (no endpoint makes an expired session). The token gets `401 UNAUTHENTICATED` from `GET /api/v1/me` before the sweep, and again after `runSweep` deletes its row.
6. **Hourly sweep, at the time of each sweep, stopped by close:** with `mock.timers` (node:test) enabled before `buildApp`, mocking only `setInterval` and `Date` (so `setTimeout` stays real for Fastify), starting at a fixed time, and a file database. Probed 2026-11-18: the mocked `setInterval` returns a handle with `unref`, and `clearInterval` clears it.
   - the app starts the timer at `SWEEP_INTERVAL_MS`, which is `3_600_000`, and calls `unref` on it: the test wraps the mocked `setInterval` with `mock.method`. The wrapper calls the mocked `setInterval`, replaces the returned handle's `unref` with a mock, and only then returns the handle, because `buildApp` calls `unref` right away. After `buildApp`, `setInterval` was called once with `SWEEP_INTERVAL_MS` as its delay, and `unref` once
   - a session written before startup that expires 30 minutes after it survives the startup sweep; a `mock.timers.tick` of one hour deletes it, so each sweep uses the current time, not the startup time
   - **a failed hourly sweep doesn't stop the server:** with the test holding the write lock (`BEGIN IMMEDIATE` on its own connection, as in check 4) and an expired row in the database, a `mock.timers.tick` of one hour throws nothing, and `GET /api/health` still answers `200`. After the test commits, the next one-hour tick deletes the row. This fails if the timer calls `deleteExpiredSessions` without `runSweep`'s catch.
   - `app.close()` stops the timer: with `clearInterval` wrapped by `mock.method` before the close, the close calls it once, with the handle `setInterval` returned. (Checking that a row stays after the next tick can't fail: the closed database makes that sweep fail, and `runSweep` catches the error.)
7. **A failed sweep doesn't stop the server:** `runSweep(db, log)`, the function the startup sweep and the timer both call, is given a database whose `prepare` throws. It logs one `error` with the message `sessions: sweep failed`, and returns without throwing. With a database that has one expired row, it logs one `info`, `sessions: deleted 1 expired`; with nothing expired, it makes no log call at all. An uncaught error in a `setInterval` callback would end the process, so the catch is what keeps the server up. With the real database again, the next call deletes the expired rows. A unit test with a stub `db` and a stub `log` that records its calls.
8. **Upgrade:** opening a file database at version 1 (made by applying only `MIGRATIONS[0]` and setting `PRAGMA user_version = 1`) applies migration 2: `PRAGMA user_version` becomes 2, and `sqlite_master` lists the index `sessions_expires_at`. `PRAGMA busy_timeout` on the returned connection reads `{ timeout: 0 }`. After closing it, opening the same file again, now at version 2 so no migration runs, also returns a connection whose busy timeout reads `{ timeout: 0 }`.
9. **Two processes migrating at once:** on a file database at version 1, created in WAL mode as every database `openDb` makes is, the test takes the write lock with `BEGIN IMMEDIATE` on its own connection, and starts two child processes. Each child writes `start` to stdout with `fs.writeSync`, a synchronous write, right before it calls `openDb` on the file. The test commits 200 ms after it has read `start` from both, and fails if they haven't both written it within 10 seconds. Both children exit with code 0, and the database is at version 2 with the index. Run against today's runner, both children fail with `database is locked` (see the probe under "Data model"), so this check can fail. It's in `server/test/sessions.test.ts` too, and passes the same way.
10. `npm run check` passes locally and in CI. The 001 doc no longer lists this as a gap, and `docs/devops.md`'s migrations section describes the lock, the recheck, and the busy timeout.

## Readiness review

Refined 2026-11-18 by Claude Code (claude-opus-5-5).

- **Goal, restated:** housekeeping for whoever runs the server. Expired sessions are already rejected, but their rows are never deleted. The smallest fix is a sweep at startup and hourly, an index for it in migration 2, and a fix to the migration runner so two processes can apply that first upgrade at once.
- **Is it needed:** not built: only logout deletes a session (`server/src/app.ts`), and no sweep or timer exists (searched `server/src` for `expires_at`, `sweep`, `setInterval`). No open PR overlaps it. Never dropped: the backlog history shows it as `idea`, then `designed`.
- **Definition of Ready:**
  1. pass: who it's for, what changes, and what doesn't are in the Summary
  2. pass: see "Is it needed"
  3. pass: an out-of-scope list
  4. pass: the server and its docs only, one behavior
  5. pass: the SQL, the log messages, the files, and the docs it changes
  6. pass: "Tasks for the user: none"
  7. pass: each check says where it's tested and what shows it passed; checks 6 and 9 were rewritten so they can fail
  8. pass: rule 2 (each instance sweeps, idempotently; the migration lock) and rule 3 (001 and devops.md); rules 1, 4, and 5 don't apply
  9. pass: no trigger but the timer, a failed sweep is logged and retried, no new gaps
  10. pass: no open questions; the decisions are below
- **Questions and answers:** Q1 keep the migration runner's fix in this ticket → yes. Q2 sweep at startup and hourly, with a fixed interval → yes. Q3 no grace period → yes. Q4 the sweep in a new `server/src/sessions.ts` → yes.
- **Probes:** the migration race (today's runner fails, the fix passes, holding the lock makes it certain); `node:test` mock timers with an unref'd interval, a mocked `Date`, and a child's synchronous `start` signal.
- **Review round 1:** Codex (gpt-6.1-sol) and opencode (ollama-cloud/glm-5.3).
  - Both restatements match the goal above.
  - Codex 1 and opencode 1, the same finding: no check makes a sweep fail. Evidence: the doc's "Logging" line promises it; no check tests it. Fixed: check 7, `runSweep`, and the exact error message.
  - Codex 2: check 9 waited a fixed 500 ms, so a slow child could miss the overlap. Evidence: the check's text. Fixed: each child writes `start` synchronously before `openDb`, and the test commits 200 ms after both have (probed).
  - Codex 3: check 6 never moved the clock, so a sweep that reused the startup time would pass. Evidence: check 6 mocked only `setInterval`. Fixed: it mocks `Date` too, with a session that expires between sweeps.
  - opencode 2: checks 2 and 5 didn't say how an expired session is made, and no endpoint makes one. Evidence: `server/src/app.ts` sets `expires_at` to now + 30 days. Fixed: check 5's setup, and check 2's reason marked as not tested.
  - opencode 4: the doc said login checks `expires_at`; it's `requireUser`, behind `GET /api/v1/me`. Evidence: `server/src/app.ts`. Fixed.
  - opencode 5: "the table only grows" ignores logout. Evidence: the logout route deletes its row. Fixed.
  - opencode 6: a version-1 database needs migration 1's SQL, and `MIGRATIONS` isn't exported. Evidence: `server/src/db.ts`. Fixed: export it.
  - Dropped: 1. opencode 3 (needs a run): would the mocked `setInterval` handle lack `unref`? The probe printed `handle: object | unref: function` and `cleared: ok`.
  - Kept for later rounds: opencode, with 5 kept findings to Codex's 3.
- **Review round 2:** opencode (ollama-cloud/glm-5.3). Its restatement matches. It checked each round-1 fix against the code, and they hold.
  - Finding 1: check 6's "row stays after close" can't fail, because a sweep on the closed database fails and is caught. Evidence: the `onClose` hook in `server/src/app.ts` closes the database. Fixed: the check requires `clearInterval` to be called by the close.
  - Finding 2: the `info` log, and logging nothing for an empty sweep, had no check. Evidence: the "Logging" line. Fixed: check 7 covers both.
  - Finding 3 (needs a run): a version-1 file made without WAL makes check 9 fail even with the fix. Probe: on a non-WAL file, the child's WAL pragma failed at once with `database is locked` while the lock was held; on a WAL file it passed. Fixed: check 9's file is made in WAL mode, and a brand-new file is a known gap.
  - Finding 4: the busy timeout lasts for the connection, so a request could wait up to 5 seconds, which contradicts "every response stays the same". Evidence: the route handlers write on the same connection. Fixed: the timeout goes back to 0 after the migrations, because `node:sqlite` is synchronous and a wait would block the whole server.
  - Dropped: 0.
- **Review round 3:** opencode (ollama-cloud/glm-5.3). Its restatement matches. The round 1 and 2 fixes hold.
  - Finding 1: no check shows the startup sweep goes through `runSweep`'s catch, so a busy database at startup could stop the server from starting. Evidence: check 7 tests `runSweep` alone. Fixed: check 4 holds the write lock while the app starts (probed: the sweep's `DELETE` fails at once under it).
  - Finding 2: no check shows the busy timeout goes back to 0. Evidence: no check reads `PRAGMA busy_timeout`. Fixed: check 8 reads it (`{ timeout: 0 }`).
  - Finding 3: no check shows the timer is `unref`'d. Evidence: every test closes its app, which clears the timer anyway. Fixed: check 6 mocks the handle's `unref`.
  - Dropped: 0.
- **Review round 4:** Codex (gpt-6.1-sol) and opencode (ollama-cloud/glm-5.3), run separately, at the user's request. Both restatements match. opencode checked the round 1–3 fixes against the code, and they hold.
  - Codex 1 and opencode 2, the same finding: no check makes an hourly sweep fail, so a timer wired to `deleteExpiredSessions` without `runSweep`'s catch would pass. Evidence: check 6 tests only a sweep that works; check 7 calls `runSweep` directly. Fixed: check 6 holds the write lock during a tick, then checks that the next tick deletes the row.
  - Codex 2: the close check didn't say which handle `clearInterval` gets. Evidence: check 6's last bullet. Fixed: it must be the handle `setInterval` returned.
  - Codex 3: nothing checks the interval is an hour; a 45-minute timer passes the one-hour tick. Evidence: check 6. Fixed: `setInterval` is called with `SWEEP_INTERVAL_MS`, which is `3_600_000`.
  - opencode 1: "after the last migration" can be read as inside the loop, so on an already-current database, which is every restart after the upgrade, the timeout would stay 5000. Evidence: "Data model" step 1; check 8 reads the timeout only after a migration ran. Fixed: the reset is after the loop, whether or not a migration ran, and check 8 reopens the file at version 2 and reads it again.
  - opencode 3: the `unref` mock, read in order, is set after `buildApp` has already called `unref`, so it can never count a call. Evidence: check 6's first bullet, and the implementation map's "`setInterval`, then `unref`". Fixed: the wrapper replaces `unref` before returning the handle.
  - Dropped: 0.
- **Approved by the user:** 2026-11-18, after round 4. Rounds 3 and 4 found only acceptance checks that couldn't fail and wording a builder could misread, so the user chose to stop the review there.

## Decisions made for this ticket

Decided by the user on 2026-11-18, in the refinement:
- **The migration runner's fix is part of this ticket.** Migration 2 is the first one that runs on a database that already exists, so without the fix, two processes starting at once can fail (see "Data model"). It's small, and it ships with the migration that needs it.
- **Sweep at startup, then every hour, with a fixed interval and no setting.** The table grows by one row per login, so an hour is plenty, and a setting would be one more thing to document and test for no gain.
- **Delete rows as soon as they expire, with no grace period.** Nothing reads expired rows: login and `/me` already reject them, and there's no audit log that uses them.
- **The sweep goes in a new `server/src/sessions.ts`,** not in `app.ts`, which is already about 300 lines. `buildApp` only starts and stops it.
