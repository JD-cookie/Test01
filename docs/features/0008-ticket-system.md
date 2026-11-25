# The ticket system: statuses, claims, and blockers

Status: implemented.

## Summary

The repo's work is tracked as tickets: rows in a backlog table, `docs/backlog/README.md`, each with a design doc. Several agents, and the runner (see [0007-agent-runner.md](0007-agent-runner.md)), may look for work at the same time, so a script, `scripts/ticket.sh`, lists the tickets ready to build and claims one, in a way that only one agent can win. It reads only what's on `origin`: `main`'s backlog and the branches.

**For whom:** the owner, who decides which tickets are `ready`; the agents, who claim and build them; and the runner, which calls the script.

**What it guarantees:**
- Only the owner makes a ticket `ready`, in a PR the owner merges. Nothing changes a status on `main` on its own.
- A ticket is claimed by at most one agent: whoever creates its branch on `origin` first.
- A `ready` ticket whose row names other items in "Blocked by: …" isn't claimed until each of them is built. It **waits**, and needs no second approval or edit once they are.

How ticket numbers are given and reserved when a ticket is marked `ready` is in [0003-refine-ticket-skill.md](0003-refine-ticket-skill.md). How a claimed ticket is built and taken through its PR is in "How it works" in `docs/backlog/README.md` and the `next-ticket` skill.

## Concepts

- **Row:** one line of the backlog's table: `| # | Item | Area | Status | Notes |`. Read with `|` as the separator, the `#` cell is field 2, Item field 3, Status field 5, and Notes field 6 (field 1 is the empty text before the first `|`). Cells are trimmed of spaces.
- **Ticket:** a row with a four-digit number in `#` and an Item that links its design doc, `[<title>](NNNN-<slug>.md)`. `NNNN-<slug>` is its name and its branch's name.
- **Claim:** the ticket's branch on `origin`, made by `scripts/ticket.sh claim`, whose first commit after `main` is the claim commit.
- **Blocker:** an item named in a row's "Blocked by: …" notes.
- **Built:** a blocker whose row is gone from `main`'s backlog and whose title is listed in `main`'s `docs/tickets/README.md`, or, for features built before the backlog (0001 and 0002), in the Features table of `main`'s `docs/README.md`, as `| [<title>](`.
- **Waiting:** a `ready` ticket with at least one blocker not built.

## User-facing behavior

### Statuses

| Status | Meaning | Who sets it |
|---|---|---|
| `idea` | A row, no design doc yet | Anyone |
| `designed` | Has a design doc, `docs/backlog/<slug>.md`, not ready to build | Anyone |
| `ready` | Has a number and a design doc `docs/backlog/NNNN-<slug>.md` that meets the backlog's Definition of Ready. Claimable unless it's waiting. | The owner, in a PR the owner merges (an agent may make the edit after the owner's approval in the same conversation) |
| `in progress (claim <id>, <agent>, <time>)` | Claimed. Only on the ticket's branch: it reaches `main` with the ticket's PR, which removes the row. | `scripts/ticket.sh claim` |

There's no status for waiting: a waiting ticket's row says `ready` and keeps its "Blocked by: …". Whether it waits is worked out each time the script reads `main`.

### Blockers

An item that can't start until others are built begins its Notes cell with `Blocked by: `, then the items' titles. The blockers are read from the row's Notes cell on `origin/main`:
- Only a cell that starts `Blocked by: ` (after spaces), or is exactly `Blocked by:`, has blockers. A cell that mentions "Blocked by" later has none.
- A cell that starts "Blocked by" written any other way, in any case, with or without the colon or the space after it (`Blocked By: A`, `Blocked by:A`, `blocked by A`), counts as one unknown blocker, shown as `(a "Blocked by" not written as "Blocked by: <title>; <title>")`: the owner meant it to wait, and its list isn't read.
- The list runs to the first `. ` (a period and a space) or to the end of the cell, whichever comes first, and a trailing `.` is dropped. The rest of the cell is free text.
- Titles are separated by `; `, with spaces trimmed. A title is plain text, as the Item column writes it.
- An empty list or an empty entry (`Blocked by: .`, `Blocked by: A; ; B`, or `Blocked by:` and nothing else) counts as one unknown blocker, shown as `(an empty entry in "Blocked by")`, once however many empty entries there are, at the place of the first.

For each title:
- **Not built, in the backlog:** some row's Item cell is the title, or starts with a link whose text is the title (`[<title>](`).
- **Built:** no such row, and `docs/tickets/README.md` or `docs/README.md` on `origin/main` has `| [<title>](`.
- **Unknown:** neither, for example a typo, or a blocker that was dropped. It counts as not built, so a ticket is never claimed past a blocker nobody can find.

`docs/tickets/README.md` and `docs/README.md` are read only when a blocker of a `ready` row has no row in the backlog, the only case in which they decide anything. If either can't be read then, the command exits 2, so a failed read can never make a blocker look built.

Once every blocker is built, the same `ready` row is free to claim, with no edit to it.

### Commands

```text
scripts/ticket.sh list
scripts/ticket.sh claim next [agent-name]
scripts/ticket.sh claim NNNN-<slug> [agent-name]
scripts/ticket.sh verify NNNN-<slug>
```

The script runs from anywhere in a checkout: it changes to the repo's top folder first. Outside a git checkout, it exits 2 with `ticket: not inside a git checkout`. The agent name defaults to `$TICKET_AGENT`, then to the user's login name. Every message below goes to stderr, prefixed `ticket: `, except `list`'s lines and the two success lines, which go to stdout. Any other first argument, or a missing ticket name, exits 2 with a usage line.

#### `list`

Fetches `main`, lists `origin`'s branches, and prints one line for each `ready` row, in backlog order. The first state that applies:

| Line | When |
|---|---|
| `<slug>  waiting on: <title>; <title>` | It has a blocker not built. Only those are listed, in the row's order; an unknown one is `<title> (not in the backlog or built)`. Shown even if the branch exists or the doc is missing. |
| `<slug>  not claimable: docs/backlog/<slug>.md is missing on main` | Its design doc isn't on `main`. |
| `<slug>  claimed (branch exists on origin)` | Its branch exists on `origin`. |
| `<slug>  ready` | Free to claim. |

A row whose `#` cell doesn't match the number of the doc it links (`0003` linking `0004-x.md`) prints `<doc's slug>  not claimable: the row's # column doesn't match the doc's number. Fix the row on main`, whatever its status. Rows with any other status print nothing. Only a line that is exactly `<slug>  ready` (two fields) is free: that's what `claim next` and the runner look for.

Exit codes: 0; 4 `couldn't reach origin` (the fetch) or `couldn't reach origin to list the claimed tickets`; 2 `couldn't read docs/backlog/README.md on origin/main`, `couldn't read docs/tickets/README.md on origin/main, so the blockers of <slug> can't be checked`, or the same for `docs/README.md`. On exit 2 or 4 it prints no ticket lines.

#### `claim NNNN-<slug>`

Checks, in this order, each refusing before anything is created:

| Exit | Message | When |
|---|---|---|
| 2 | `not a ticket name: <name> (expected NNNN-slug)` | Not four digits, a dash, and at least one of `a-z0-9-` |
| 2 | `agent name may only use letters, digits, and . _ @ -` | Empty, or any other character |
| 2 | `commit, stash, or remove your changes first, including untracked files (see git status)` | The checkout has changes, untracked files included |
| 4 | `couldn't reach origin` | `main` can't be fetched |
| 2 | `<slug> isn't a numbered ticket in docs/backlog/README.md on origin/main` | No ticket row with that name |
| 2 | `<slug> has status '<status>' on origin/main, not 'ready'` | |
| 2 | `<slug> is waiting on: <title>; <title> (not in the backlog or built). It can be claimed once each one is built; one that's not in the backlog or built needs the row fixed on main.` | It's waiting (the list as in `list`). Before the branch checks, so a ticket both waiting and claimed gets 2, as `list` shows it as waiting. |
| 2 | `<slug> is ready but its design doc docs/backlog/<slug>.md is missing on origin/main` | |
| 4 | `couldn't reach origin` | `origin`'s branch can't be looked up after three tries, 2 seconds apart |
| 3 | `<slug> is already claimed: the branch exists on origin` | |
| 2 | `a local branch <slug> exists. If it's an old claim attempt, run: scripts/ticket.sh verify <slug>` | |

Then it makes the claim (see "Processing"). Its outcomes:

| Exit | Output |
|---|---|
| 0 | stdout `claimed <slug> (claim <id>) on branch <slug>`; the checkout is on the branch, tracking `origin`'s |
| 2 | `couldn't create the branch <slug>`, `couldn't create a temporary file`, `couldn't write the claim to docs/backlog/README.md`, `couldn't find the status cell of <slug> in docs/backlog/README.md`, or `the claim commit failed (see above), so nothing was pushed. If the commit-msg hook is missing its tools, run npm install in the repo root.` The checkout is put back as it was. |
| 3 | `lost the race for <slug>: another agent created its branch first` |
| 4 | `couldn't reach origin to check the claim. Your local branch <slug> is kept; run: scripts/ticket.sh verify <slug>`, or `the push failed and origin has no branch <slug>, so nobody holds the claim. Try again.` (after the push's own output) |
| 4 | `the claim is yours, but main couldn't be fetched to check the ticket is still ready. Run: scripts/ticket.sh verify <slug>` |
| 4 | `the claim is yours, but the blockers of <slug> on main couldn't be read (see above). Run: scripts/ticket.sh verify <slug>`, after the failed read's own message |
| 5 | `the claim is yours, but on main <slug> is now '<status or gone>', not 'ready'. Don't build it: ask the user. Leave the branch; only the user releases a claim.` |
| 5 | `the claim is yours, but on main <slug> is now waiting on: <title>. Don't build it: ask the user. Leave the branch; only the user releases a claim.` |
| 5 | `the claim is yours, but docs/backlog/<slug>.md changed on main since the claim. Don't build it: ask the user. Leave the branch; only the user releases a claim.` |

If setting the branch's upstream fails after a won claim, it warns `the claim is yours, but setting the branch's upstream failed. Later, run: git push -u origin <slug>`, and the outcome stays 0.

#### `claim next`

Checks the agent name and the checkout as above, then runs `list` and takes its free lines (exactly `<slug>  ready`), in order, so it skips claimed, waiting, and not claimable tickets. For each, it runs `claim <slug>` as a separate process:
- exit 3: prints `<slug> was taken, trying the next one`, and tries the next
- exit 2, the first time: prints `<slug> couldn't be claimed, reading the ready tickets again`, and starts over once from a new `list` (the owner may have withdrawn it)
- any other exit, or exit 2 the second time: ends with that exit code

With no free ticket left, it exits 3 with `no free ready ticket: see scripts/ticket.sh list`.

#### `verify NNNN-<slug>`

For a claim whose outcome wasn't known (exit 4), with the local branch it left:

| Exit | Output | When |
|---|---|---|
| 2 | `there's no local branch <slug>` | |
| 4 | `couldn't reach origin` | |
| 0 | stdout `claimed: origin's <slug> is your claim commit` | `origin`'s branch is the local one, and the check on `main` (below) passes; else that check's 4 or 5 |
| 3 | `origin has no branch <slug>, so the claim didn't happen. Delete the local branch (git branch -D <slug>) and claim again.` | |
| 3 | `origin's <slug> is another agent's commit: the ticket isn't yours. Delete the local branch: git branch -D <slug>` | |

### Exit codes

- **0:** listed, claimed, or verified.
- **2:** usage, a dirty checkout, an agent name or ticket name that isn't allowed, not a `ready` ticket or a waiting one, a local branch in the way, a failed local step, or a file on `main` that couldn't be read.
- **3:** already claimed, or the race lost; for `claim next`, no free ticket left.
- **4:** `origin` couldn't be reached, or the claim's outcome isn't known: see the message.
- **5:** the claim is yours, but on `main` the ticket was withdrawn, its design doc changed, or it was made to wait, while it was claimed. Don't build it; ask the owner.

## Processing

### How a claim is made and decided

1. **Read `main`:** the backlog is read from `origin/main`, never from the working tree. Claims show as branches on `origin`, and reach `main` only when the ticket's PR merges.
2. **Make the claim commit:** a new local branch `NNNN-<slug>` from `origin/main`, with one commit that sets the ticket row's Status cell to `in progress (claim <id>, <agent>, <time>)`: `<id>` is 8 random hex digits (4 bytes of `/dev/urandom`), `<time>` is UTC as `YYYY-MM-DDTHH:MMZ`. Its message is `chore(repo): claim ticket <slug>`, with the trailers `Claim-Id: <id>` and `Claimed-By: <agent>`. The random id makes every claim commit unique: two agents making the same commit would get the same hash, and both pushes would seem to succeed.
3. **Push it create-only:** `git push --force-with-lease=refs/heads/<slug>: -u origin <slug>`. The empty lease means "only if the branch doesn't exist", and git updates the branch atomically, so only one push can create it.
4. **Decide from what `origin` holds:** the claim is won only if `origin`'s branch points at this commit. A failed push isn't proof of a lost race (the reply may have been lost), and a successful one isn't checked any other way. If `origin` has another commit, the race is lost, and the local branch is deleted. If it has none, nobody holds the claim. If it can't be reached, the local branch is kept for `verify`.
5. **Check `main` again** (`still_ready`): fetch `main`, and check that the ticket is still `ready`, that it isn't waiting (the owner may have added a blocker), and that its design doc is the same as in the claim commit's parent. Otherwise exit 5, and the branch stays.

Before the push, any failure puts the checkout back as it was: the clean tree is reset, the starting branch (or detached commit) is checked out again, and the new branch is deleted.

Two agents racing for one ticket are covered by git's create-only push: one creates the branch, and the other's push is refused, or finds another commit there in step 4.

### Releasing a claim

Only the owner releases a claim, by deleting the ticket's branch on `origin`. The ticket is free again, since on `main` it still says `ready`. Nothing in the script deletes, overwrites, or force-pushes a branch on `origin`.

## Security and configuration

- **Who triggers it:** whoever runs the script: the owner, an agent, or the runner. It reads `main` and `origin`'s branches, and writes only the claim branch, create-only. Only the owner marks a ticket `ready`, in a PR the owner merges, so only the owner can add or remove a blocker on `main`.
- **Inputs from the backlog:** the agent name and ticket name end up in the backlog table, so both are checked as whole values (no `|`, spaces, or new lines).
- **A blocker read wrongly** would let a ticket be built too early, so every doubt counts as not built: an unknown title, an empty entry, a misspelled "Blocked by". The worst case is a ticket that waits until the owner fixes its row.
- **`origin` or `main` can't be read:** exit 4 or 2, never an empty list, so a failed read can't show a claimed ticket as free or a blocker as built.
- **Logging:** only the messages above. `list` and the claim messages say what a ticket waits on.
- **Configuration:** `TICKET_AGENT`, the default agent name. Nothing else.

### Known gaps

- A title with `; ` or `. ` in it can't be named as a blocker.
- A blocker is matched by title, so renaming a blocker's row makes it unknown until the row naming it is updated. That's safe: the ticket waits.
- A ticket made to wait after it was claimed and checked (step 5) isn't noticed by the script: the builder works on.

## Implementation map

- `scripts/ticket.sh`: POSIX `sh` and `awk`. `tickets()` reads the numbered rows; `waiting_on()` reads a row's blockers and checks each; `ready_tickets()` is `list`; `claim()`, `claim_next()`, `verify()`, and `still_ready()` as above.
- `scripts/test/ticket.test.sh`: the acceptance checks below, against a scratch bare `origin` and a scratch clone. `npm run test:scripts` runs it, with `scripts/test/agent-run.test.sh`, in the pre-commit hook (when `scripts/` changes) and in CI's `scripts` job.
- `docs/backlog/README.md`: the statuses, "How it works", and the table itself.
- Callers: the `next-ticket` and `refine-ticket` skills, and `scripts/agent-run.sh`, which counts only a `list` line of exactly `<slug>  ready` as free.

## Acceptance checks

All are in `scripts/test/ticket.test.sh` unless they say otherwise. Each runs the script in a scratch clone of a scratch bare `origin`, whose `main` has a backlog, and a `docs/tickets/README.md` and `docs/README.md` when the check says so. What shows it passed: `npm run test:scripts` prints `ok N`.

1. **Waiting:** a `ready` row `0012-thing` blocked by an item whose row is in the backlog: `list` prints `0012-thing  waiting on: <title>`; `claim next` exits 3 and creates no branch on `origin`; `claim 0012-thing` exits 2 with its message and creates no branch, local or on `origin`.
2. **Built:** the same row, with the blocker's row gone and the blocker in `docs/tickets/README.md`: `list` prints `0012-thing  ready`, and `claim next` claims it. With the blocker in `docs/README.md`'s Features table instead, the same.
3. **Two blockers, one built:** `list` names only the one not built.
4. **Unknown:** a blocker in neither the backlog nor the built lists: `list` prints `waiting on: <title> (not in the backlog or built)`, and `claim next` skips it.
5. **Order:** a waiting ticket above a free one: `claim next` claims the free one.
6. **Row gone but not in the index:** a blocker whose row was removed on `main`, and that isn't in either built list, is unknown, so the ticket waits.
7. **Notes after the list:** `Blocked by: A; B. Part 2 of 3.` reads `A` and `B` only; a cell that doesn't start with `Blocked by: ` has no blockers, even if it mentions "Blocked by" later.
8. **Linked blocker row:** a blocker whose row's Item is `[<title>](<slug>.md)` is found as not built.
9. **No index:** `main` with no `docs/tickets/README.md` and no blocked rows: `list` and `claim next` work as before.
10. **Failed read:** a `ready` row blocked by a title with no row, and no `docs/tickets/README.md` on `main`: `list` exits 2 with `couldn't read docs/tickets/README.md`, and prints no `ready` line.
11. **Blocker added after the claim:** after a won claim, `main` gets a commit that adds an unbuilt blocker to the row: `verify 0012-thing` exits 5 with its message. If the new blocker has no row and `main` has no `docs/tickets/README.md`, so the blockers can't be read, it exits 4 with its message, and the branch stays.
12. **Unchanged cases:** with their blockers built, a claimed ticket, a missing design doc, and a mismatched number print the same lines as with no blockers.
13. **Empty entries and a misspelled "Blocked by":** `Blocked by: .`, `Blocked by:`, and `Blocked by: A; ; B` (A and B built): `list` prints `waiting on: (an empty entry in "Blocked by")`. `Blocked By: A.`, `Blocked by:A`, and `blocked by A and B.`: `list` prints `waiting on: (a "Blocked by" not written as "Blocked by: <title>; <title>")`. `claim next` skips them all.
14. **Waiting and claimed:** a waiting ticket whose branch is on `origin`: `list` prints its waiting line, and `claim` of it exits 2, not 3.
15. **The runner** (`scripts/test/agent-run.test.sh`, its check 1): with its seed's ticket waiting on a blocker whose row is in the seed's backlog, and no `docs/tickets/README.md`, the run logs `no ready ticket`, exits 0, and calls neither `claude` nor `claim next`.
16. **`refine-ticket`, by reading:** its steps 8 and 9.1 tell the owner a blocked ticket will wait, and stop only for an unknown blocker.
17. **`list`'s states:** a free ticket prints `<slug>  ready`; a claimed one `<slug>  claimed (branch exists on origin)`; one whose doc is missing `<slug>  not claimable: docs/backlog/<slug>.md is missing on main`; a mismatched number `not claimable: the row's # column doesn't match the doc's number. Fix the row on main`; `designed` and `idea` rows print nothing.
18. **A won claim:** `claim 0012-thing tester` exits 0 and prints `claimed 0012-thing (claim <id>) on branch 0012-thing`. `origin`'s `0012-thing` is the local branch's commit, its parent is `main`, its only change is the row's status, `in progress (claim <id>, tester, <time>)`, and its message has `Claim-Id: <id>` and `Claimed-By: tester`.
19. **Already claimed:** with `0012-thing` already on `origin`, `claim 0012-thing` exits 3 and leaves no local branch; `claim next` with one other free ticket claims that one.
20. **Refused before anything is made (exit 2):** a checkout with an untracked file; an agent name with a space; a name that isn't `NNNN-slug`; a `NNNN-slug` with no numbered row on `main`. None leaves a new branch, local or on `origin`.
21. **Withdrawn after the claim (exit 5):** after a won claim, `main` sets the row back to `designed`, or changes the design doc: `verify 0012-thing` exits 5 with its message, and the branch on `origin` stays.
22. **`verify`:** with the local branch equal to `origin`'s, exit 0 and `claimed: origin's 0012-thing is your claim commit`; with no branch on `origin`, exit 3; with another agent's commit there, exit 3.

Two agents racing for one ticket stay a check by reading the code: the create-only push is git's, and checks 18 and 19 cover both outcomes one at a time.

## Changes

- 0008: Mark a blocked ticket `ready` before its blockers are built ([ticket](../tickets/0008-ready-before-blockers.md))
