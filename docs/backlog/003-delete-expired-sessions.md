# 003: Delete expired session rows

Status: **ready**. Ticket design doc: it moves to `docs/features/` in the PR that builds it.

## Summary

Sessions expire 30 days after login (see [001](../features/001-accounts.md#data-model)), and an expired token is already rejected with `401`. But its row stays in `sessions` forever. This feature deletes expired rows on a schedule, so the table only holds sessions that can still be used. It's housekeeping: nothing changes for users or for the API.

## Concepts

- **Sweep:** one `DELETE` of every session whose `expires_at` has passed.

## User-facing behavior

None. Expired sessions already behave as logged out.

## API

No changes. Rejecting an expired token doesn't depend on the sweep: a session with `expires_at` in the past gets `401 UNAUTHORIZED` whether or not its row has been deleted yet.

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

## Security and configuration

- No new settings. The interval (1 hour) is a constant. Tests call the sweep function directly instead of waiting for the timer.
- In 001's Security section, delete the "Deleting expired session rows" line from the known gaps.

## Implementation map

- `server/src/db.ts`: migration 2 (the index).
- `server/src/app.ts` (or a small `server/src/sessions.ts`): `deleteExpiredSessions(db, now): number`, which returns the number of rows deleted. Plus the startup sweep, the hourly timer, and clearing it in the existing `onClose` hook.
- `server/test/`: tests for the acceptance checks below.

## Acceptance checks

1. With one expired and one valid session in the database, a sweep deletes the expired row and keeps the valid one. It returns 1.
2. A session whose `expires_at` equals `now` is deleted. Its token is already rejected at that moment, because a session is valid only while `expires_at > now`.
3. A sweep with nothing expired deletes nothing and returns 0.
4. The server sweeps at startup: expired rows in the database before `buildApp` are gone once the app is ready.
5. A token whose session expired gets `401` both before and after the sweep.
6. `app.close()` stops the timer: the test process exits without hanging.
7. Opening an existing version-1 database applies migration 2. `PRAGMA user_version` becomes 2, and the index exists.
8. `npm run check` passes, and the 001 doc no longer lists this as a gap.
