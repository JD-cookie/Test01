# Mark a blocked ticket `ready` before its blockers are built

Status: built (2026-11-25).

**Spec docs changed:** `docs/features/0008-ticket-system.md` (new in this PR), [0003-refine-ticket-skill.md](../features/0003-refine-ticket-skill.md), [0007-agent-runner.md](../features/0007-agent-runner.md), [docs/README.md](../README.md).

## Summary

**For whom:** the owner, who decides which tickets are `ready`, and the agents and the runner that claim them.

**The problem:** an item whose Notes start "Blocked by: …" can't be marked `ready` until every item named there is built. That rule is in "How it works" in `docs/backlog/README.md` ("Blocked items"), and in the `refine-ticket` skill: step 8 stops before asking "Mark it ready?", and step 9.1 stops the ready PR. So a design the owner has approved waits, and the owner has to come back later for a second round of approval and a second ready PR. This happened with the runner's parts 2 and 3, which are designed but blocked by part 1 (ticket 0007, built 2026-11-24).

**Current behavior:**
- `scripts/ticket.sh list` shows every `ready` row on `main` as `ready`, `claimed (…)`, or `not claimable: …`. It never reads the Notes column.
- `claim next` takes the first `ready` row it shows as free, and `claim NNNN-<slug>` takes the named one if it's `ready`.
- Neither checks "Blocked by", since a `ready` row can't have unbuilt blockers today.

**Behavior wanted:**
- The owner marks a ticket `ready` once, when they approve its design, even if what blocks it isn't built yet. Its row keeps its "Blocked by: …".
- `scripts/ticket.sh` treats a `ready` ticket with an unbuilt blocker as **waiting**: `list` shows it with what it waits on, `claim next` skips it, and `claim NNNN-<slug>` refuses it.
- Once every blocker is built, the same row is free to claim, with no edit to it. "Built" is ticket 0006's rule: the blocker's row is gone from the backlog, and it's listed in `docs/tickets/README.md`, or, for 0001 and 0002, in the Features table of `docs/README.md`.
- `refine-ticket` no longer stops on a blocked item: it tells the owner the ticket will wait, and asks "Mark it ready?" as usual.

**What doesn't change:**
- Only the owner marks a ticket `ready`, and nothing changes a status later on its own.
- A ticket's number, branch name, claim commit, and the claim's race rules.
- The runner (`scripts/agent-run.sh`): it already counts only a `list` line of exactly `<slug>  ready` as free (`awk '$2 == "ready" && NF == 2'`), so a waiting ticket isn't free to it either. A test shows it.
- The "Blocked by: …" convention itself: the Notes start with it, naming the items by title.

## Concepts

- **Blocker:** an item named in a row's "Blocked by: …" notes.
- **Built:** a blocker whose row is gone from `main`'s backlog and whose title is in `main`'s `docs/tickets/README.md` (`| [<title>](`), or in the Features table of `main`'s `docs/README.md`.
- **Waiting:** a `ready` ticket with at least one blocker not built.

## Behavior

### Reading the blockers

The blockers are read from a row's Notes cell (the fifth column, `awk -F'|'` field 6) on `origin/main`:
- Only a cell that starts `Blocked by: ` (after spaces) has blockers.
- The list runs to the first `. ` (a period and a space) or to the end of the cell, whichever comes first, and a trailing `.` is dropped.
- Titles are separated by `; `, with spaces trimmed. A title is plain text, as the backlog's rows write them today. A title can't contain `; ` or `. `.
- **An empty list or an empty entry** (`Blocked by: .`, `Blocked by: A; ; B`, or `Blocked by:` and nothing else) counts as one unknown blocker, shown as `(an empty entry in "Blocked by")`. So a row whose list can't be read is never claimable.

For each title:
- **Not built, in the backlog:** a row's Item column (field 3) is the title, or starts with a link whose text is the title (`[<title>](`). That's the same match `refine-ticket` step 9 uses.
- **Built:** no such row, and the title is in `docs/tickets/README.md` or `docs/README.md` on `origin/main`, as `| [<title>](`.
- **Unknown:** neither, for example a typo, or a blocker that was dropped. It counts as not built, so the ticket is never claimed past a blocker nobody can find.

`docs/tickets/README.md` and `docs/README.md` are read only when a blocker of a `ready` row has no row in the backlog, the only case where they decide anything. So a repo without them (the runner's tests) works as before, and so does one whose `ready` rows' blockers all still have rows.

### `scripts/ticket.sh list`

Each `ready` row gets one line, as now, in backlog order. A waiting ticket's line is:

```text
0012-thing  waiting on: <title>; <title>
```

listing only its blockers not built, in the row's order. An unknown one is `<title> (not in the backlog or built)`. These come before the other states: a waiting ticket is shown as waiting even if its branch exists or its doc is missing. Lines for tickets with no blockers, or with all blockers built, are unchanged.

### `scripts/ticket.sh claim next`

It skips a waiting ticket, as it skips a claimed one: its free list is the lines that are exactly `<slug>  ready`, which a waiting line isn't. If every ready ticket is waiting or claimed, it exits 3, as now.

### `scripts/ticket.sh claim NNNN-<slug>`

A waiting ticket is refused before anything is created, with exit 2 (not a ready ticket). The check comes right after the one that the row is `ready`, and before the ones for the design doc, the branch on `origin` (exit 3), and a local branch, so a ticket that's both waiting and claimed gets exit 2, as `list` shows it as waiting. The message:

```text
ticket: NNNN-<slug> is waiting on: <title>; <title> (not in the backlog or built). It can be claimed once each one is built; one that's not in the backlog or built needs the row fixed on main.
```

### After a won claim

`still_ready` also checks that the ticket isn't waiting on `main`: the owner may have added a blocker while it was claimed. If it is, exit 5, as for a ticket that changed, with:

```text
ticket: the claim is yours, but on main NNNN-<slug> is now waiting on: <title>. Don't build it: ask the user. Leave the branch; only the user releases a claim.
```

### `refine-ticket`

- **Step 8:** if the row says "Blocked by: …" and something it names isn't built, tell the owner that the ticket will be marked `ready` but wait until those are built, naming them, and ask "Mark it ready?" as usual. Don't stop.
- **Step 9.1:** the check prints `not built: <title>` for a blocker that isn't built, as information for the PR's description, not a stop. It stops only for an **unknown** blocker: `unknown: <title> (not in the backlog or built)`, since that's a typo or a dropped item, which the owner fixes in the row first. An empty entry in the list stops it too, since `scripts/ticket.sh` counts it as an unknown blocker.
- The PR's description names the blockers it waits on.

## Security and failure modes

- **Who triggers it:** whoever runs `scripts/ticket.sh` (the owner, an agent, or the runner). It reads `main` and the branches on `origin`, as now. Only the owner marks a ticket `ready`, in a PR the owner merges, so only the owner can add or remove a blocker on `main`.
- **A blocker read wrongly** would let a ticket be built too early, so every doubt counts as not built: an unknown title, a list that can't be read. The worst case is a ticket that waits until the owner fixes its row.
- **`origin` or `main` can't be read:** as now, exit 4 or exit 2 with the message. A failed read of `docs/tickets/README.md` or `docs/README.md` when they're needed is exit 2 ("couldn't read …"), never an empty list, so a failure can't make blockers look built.
- **Logging:** `list` and the claim messages say what a ticket waits on. Nothing else is logged.
- **The project's rules:** rule 3, the docs change in the same PR (the Implementation map lists them). Rules 1, 2, 4, and 5 don't apply: no attempt limits, no server state, no versions, no workflows.
- **Known gaps:**
  - A title with `; ` or `. ` in it can't be named as a blocker. No row has one today.
  - A blocker is matched by title, so renaming a blocker's row makes it unknown until the row naming it is updated. That's safe: the ticket waits.

## Implementation map

- `docs/features/0008-ticket-system.md` (new, with this ticket's number): the spec of the ticket system as a whole, which has none today (it was built in PR #7, before the backlog had numbered tickets). Its sections are a spec doc's ("Writing a feature doc" in `docs/README.md`):
  - the statuses, and who sets each
  - `scripts/ticket.sh`'s commands (`list`, `claim next`, `claim NNNN-<slug>`, `verify`), each one's output, and every exit code (0, 2, 3, 4, 5) with its messages
  - how a claim is made and decided (the unique claim commit, the create-only push, deciding from what `origin` holds, the check on `main` afterwards), and how it's released
  - blockers, as in "Behavior" above
  - the security and failure modes, and the known gaps
  - acceptance checks for all of it, as below
  - a Changes list with this ticket's line

  What's left to the other docs: how numbers are given and reserved stays in `docs/features/0003-refine-ticket-skill.md`, which this doc links. Building a ticket stays in "How it works" and the `next-ticket` skill.
- `docs/README.md`: a Features row for the new doc, and a Changes line.
- `scripts/ticket.sh`: the blocker reading (`waiting_on()`, one `awk` pass over `main`'s backlog, then the two built lists only for a blocker with no row), `list`'s waiting state, `claim`'s refusal, `still_ready`'s check, and the header comment's exit codes.
- `scripts/test/ticket.test.sh` (new): tests against a scratch bare `origin`, like `scripts/test/agent-run.test.sh`, one `ok N` per acceptance check (1 to 14 and 17 to 22).
- `scripts/test/agent-run.test.sh`: one case, a waiting ticket, as part of its check 1 ("no ticket"), whose `setup` now also takes the ticket's notes and extra backlog rows.
- `package.json`: `test:scripts` runs both test files, `ticket.test.sh` first.
- `AGENTS.md`: the table's line for `scripts/ticket.sh` links the new spec doc and names its tests.
- `docs/backlog/README.md`: "Statuses" (`ready`), "How it works" ("Marking it ready", "Blocked items"), and a link to the new spec doc for the claim rules.
- `.agents/skills/refine-ticket/SKILL.md`: steps 8, 9.1, 9.7, and 9.8 (once merged, `list` shows the ticket as `ready`, or as `waiting on: …` if a blocker isn't built).
- `.agents/skills/next-ticket/SKILL.md`: step 1 says `claim next` skips waiting tickets.
- `docs/features/0003-refine-ticket-skill.md`: steps 8 and 9.4, acceptance check 4 (the same `ready` or `waiting on: …`), and a Changes line.
- `docs/features/0007-agent-runner.md`: the waiting case in its acceptance checks, and a Changes line.

## Acceptance checks

Checks 1 to 14 are the new behavior, 15 and 16 its other callers, and 17 to 22 the existing behavior, tested for the first time (the owner's choice). All are tests in `scripts/test/ticket.test.sh` unless they say otherwise. Each runs `scripts/ticket.sh` in a scratch clone of a scratch bare `origin`, whose `main` has a backlog, `docs/tickets/README.md`, and `docs/README.md` the test writes. What shows it passed: `npm run test:scripts` prints `ok` for each, in the pre-commit hook and in CI's `scripts` job.

1. **Waiting:** a `ready` row `0012-thing` blocked by an item whose row is still in the backlog: `list` prints `0012-thing  waiting on: <title>`; `claim next` exits 3 and creates no branch on `origin`; `claim 0012-thing` exits 2 with the message above and creates no branch, local or on `origin`.
2. **Built:** the same row, with its blocker's row removed and the blocker in `docs/tickets/README.md`: `list` prints `0012-thing  ready`, and `claim next` claims it (exit 0, its branch on `origin` is the claim commit). With the blocker in `docs/README.md`'s Features table instead, the same.
3. **Two blockers, one built:** `list` names only the one not built.
4. **Unknown:** a blocker in neither the backlog nor the built lists: `list` prints `waiting on: <title> (not in the backlog or built)`, and `claim next` skips it.
5. **Order:** a waiting ticket above a free one: `claim next` claims the free one.
6. **Row gone but not in the index:** a blocker with no row and not in either built list is unknown, so the ticket waits.
7. **Notes after the list:** `Blocked by: A; B. Part 2 of 3.` reads `A` and `B` only; a cell with no `Blocked by: ` has no blockers, even if it mentions "Blocked by" later.
8. **Linked blocker row:** a blocker whose row's Item is `[<title>](<slug>.md)` is found as not built.
9. **No index:** `main` with no `docs/tickets/README.md` and no blocked rows: `list` and `claim next` work as before.
10. **Failed read:** a `ready` row blocked by a title with no row in the backlog, and no `docs/tickets/README.md` on `main`: `list` exits 2 with `couldn't read docs/tickets/README.md`, and prints no `ready` line.
11. **Blocker added after the claim:** after a won claim, `main` gets a commit that adds an unbuilt blocker to the row. `scripts/ticket.sh verify 0012-thing`, which runs the same `still_ready` check, exits 5 with the message above.
12. **Unchanged cases:** a claimed ready ticket, a missing design doc, and a mismatched number still print what they print today.
13. **Empty entries:** `Blocked by: .` and `Blocked by: A; ; B` (A and B built): `list` prints `waiting on: (an empty entry in "Blocked by")`, and `claim next` skips the ticket.
14. **Waiting and claimed:** a waiting ticket whose branch is on `origin`: `list` prints its waiting line, and `claim` of it exits 2, not 3.
15. **The runner** (`scripts/test/agent-run.test.sh`): with its seed's ticket waiting on a blocker whose row is in the seed's backlog (`designed`), and no `docs/tickets/README.md` in the seed, the run logs `no ready ticket`, exits 0, and calls neither `claude` nor `claim`.
16. **`refine-ticket`, by reading:** steps 8 and 9.1 say what "Behavior" says. Shown by the PR's diff and the reviewers' reading.
17. **`list`'s states:** a free ready ticket prints `<slug>  ready`; one whose branch is on `origin` prints `<slug>  claimed (branch exists on origin)`; one whose doc is missing on `main` prints `<slug>  not claimable: docs/backlog/<slug>.md is missing on main`; a row whose `#` column doesn't match its doc's number prints `not claimable: the row's # column doesn't match the doc's number. Fix the row on main`; `designed` and `idea` rows print nothing.
18. **A won claim:** `claim 0012-thing tester` exits 0 and prints `claimed 0012-thing (claim <id>) on branch 0012-thing`. `origin`'s `0012-thing` is the local branch's commit, whose only change is the row's status, `in progress (claim <id>, tester, <time>)`, and whose message has `Claim-Id: <id>` and `Claimed-By: tester`.
19. **Already claimed:** with `0012-thing` already on `origin`, `claim 0012-thing` exits 3 and leaves no local branch; `claim next` with one other free ticket claims that one.
20. **Refused before anything is made (exit 2):** a checkout with an untracked file; an agent name with a space; a name that isn't `NNNN-slug`; a `NNNN-slug` with no numbered row on `main`. Each leaves no new branch, local or on `origin`.
21. **Withdrawn after the claim (exit 5):** after a won claim, `main` sets the row back to `designed`, or changes the design doc: `verify 0012-thing` exits 5 with its message, and the branch on `origin` stays.
22. **`verify`:** with the local branch equal to `origin`'s, exit 0 and `claimed: origin's 0012-thing is your claim commit`; with no branch on `origin`, exit 3; with another commit there, exit 3.

Two agents racing for one ticket stay a check by reading the code, as they were in PR #7: the create-only push is git's, and checks 18 and 19 cover both outcomes one at a time.

## Tasks for the user

None. After this merges, the owner can mark the runner's parts 2 and 3 `ready` (each with its own `refine-ticket` run), but that isn't part of this ticket.

## Out of scope

- Marking any other ticket `ready`, including the runner's parts 2 and 3.
- `scripts/ticket.sh new` and `ready` (their own backlog row).
- Changing the "Blocked by" convention, such as linked titles or blockers named by number.
- Changing a status automatically when blockers are built.
- How ready numbers are given and reserved: that stays in the `refine-ticket` spec (0003).

## Readiness review

Refined 2026-11-24 by Claude Code (claude-opus-5-5). It's the second small ticket of [0007](0007-agent-runner.md)'s task 5: the runner's first real run by hand (its check 9) builds it.

- **Goal, restated:** for the owner, who approves designs, and for the agents and runner that claim tickets. Today an approved design blocked by unbuilt work can't be marked `ready`, so the owner approves it twice. The smallest change: let a `ready` row keep its "Blocked by", have `scripts/ticket.sh` skip it until each blocker is built (ticket 0006's rule), and have `refine-ticket` stop refusing it. The owner also asked for a spec doc for the ticket system, and tests for `ticket.sh`'s existing behavior.
- **Is it needed:** already built? No: `scripts/ticket.sh` never reads the Notes column (`tickets()` reads fields 2, 3, and 5), and no spec doc or ticket doc describes waiting tickets (looked in `scripts/`, `docs/features/`, `docs/tickets/`, the skills). Overlaps? "Ticket commands for the user: `new` and `ready`" also changes `ticket.sh`, but other commands; no open PRs. Dropped before? No: `git log -p -- docs/backlog/README.md` shows only this row, added in PR #17.
- **Definition of Ready:**
  1. pass: the summary says who it's for, the problem, the current behavior and the wanted one, and what doesn't change
  2. pass: not built, no overlap, not dropped before (above)
  3. pass: an out-of-scope list, including the runner's parts 2 and 3 and `ticket.sh new`/`ready`
  4. pass: one area (the ticket system: `scripts/`, its tests, and its docs), one behavior change with its spec doc, one session
  5. pass: every output line, message, and exit code, the parsing rules, and the files, with the new ones marked new
  6. not applicable: no tasks for the user
  7. pass: 22 checks, each with its setup and result, in `scripts/test/ticket.test.sh` or `agent-run.test.sh`, shown by `npm run test:scripts` in the hook and CI; check 16 by reading
  8. pass: rule 3 (the docs in the same PR); rules 1, 2, 4, and 5 don't apply
  9. pass: who triggers it, failed reads, what's logged, and the known gaps
  10. pass: Q1 to Q6 answered and recorded
- **Questions and answers:** Q1 an unknown blocker counts as not built, and stops the ready PR → yes. Q2 a named claim of a waiting ticket is exit 2 → yes. Q3 the check after a claim includes blockers → yes. Q4 a spec doc for the ticket system → write it in this ticket. Q5 its scope (statuses, commands, claims, blockers; numbering stays in 0003) → yes. Q6 tests for the existing behavior too → yes, the main cases.
- **Review round 1:** Codex (gpt-6.1-sol) and opencode (ollama-cloud/deepseek-v4-pro), in a read-only clone of 0a8615b. Both restatements match: the owner approves once, `ticket.sh` makes the ticket wait for its blockers, and `refine-ticket` stops refusing it. Both clones and the checkout were unchanged afterwards (the checkout's only change was this section, written during the round), and so were `origin`'s branches.
  - Codex 1 (blocking): an empty list (`Blocked by: .`) or an empty entry had no defined handling. Evidence: "Reading the blockers" defined only "for each title". Done: fixed: it counts as one unknown blocker, so the ticket waits; check 13.
  - Codex 2 (minor): `refine-ticket` step 9.8 and 0003's acceptance check 4 say that after the merge `list` shows the ticket as `ready`. Evidence: `.agents/skills/refine-ticket/SKILL.md:208`, `docs/features/0003-refine-ticket-skill.md:174`. Done: fixed: both in the implementation map, saying `ready` or `waiting on: …`.
  - opencode 1 (blocking): when the built lists are read was stated two ways ("if a `ready` row has blockers" against the per-title rule), and checks 10 and 15 (then 10 and 13) didn't say whether the blocker's row exists, so a builder following the first wording would fail the runner's check. Evidence: the doc's "Reading the blockers", last paragraph, and those checks. Done: fixed: the built lists are read only for a blocker with no row; both checks say the blocker's state.
  - opencode 2 (minor): the `claim` refusal said "once they're built" even for an unknown blocker. Done: fixed: it annotates unknown ones as `list` does, and says the row needs fixing.
  - opencode 3 (minor): the spec doc's name, `0008-ticket-system.md`, differs from the ticket's slug, unlike 0003 and 0007. Done: answered: it's the owner's choice (Q4), with its reason in "Decisions made for this ticket"; nothing requires the two slugs to match.
  - opencode 4 (minor): where the waiting check runs in `claim`, relative to the exit-3 and local-branch checks, wasn't said. Evidence: `scripts/ticket.sh:199-203`. Done: fixed: right after the `ready` check, so waiting wins, as in `list`; check 14.
  - Dropped: 0.
- **Review round 2:** the same reviewers and models, blocking findings only, on acb0e69. Both restatements match. Both checked each round 1 fix and found it holds. Codex: no findings. opencode: no findings. Both clones and the checkout were unchanged afterwards, and so were `origin`'s branches. No round 3: round 2 had no kept blocking findings.
- **Approved by the user:** 2026-11-24

## Decisions made for this ticket

- **A blocker that can't be found counts as not built** (Q1, the owner, 2026-11-24): any doubt makes the ticket wait, never claimable early. `refine-ticket` stops the ready PR for one, since it's a typo or a dropped item to fix in the row first.
- **`claim NNNN-<slug>` refuses a waiting ticket with exit 2** (Q2, 2026-11-24): the existing "not a ready ticket" code, so no caller needs a new case. `claim next` already reads the list again once on exit 2.
- **The check after a won claim includes blockers** (Q3, 2026-11-24): a blocker the owner adds during a claim is a change to the ticket, like the ones `still_ready` already catches, so exit 5.
- **A spec doc for the whole ticket system, in this ticket** (Q4, 2026-11-24): the owner chose it over keeping the rules only in the backlog's "How it works" and the script's comments. Named `0008-ticket-system.md`, for the capability rather than this ticket's change.
- **Its scope** (Q5, 2026-11-24): statuses, `ticket.sh`'s commands and exit codes, claims, and blockers. Number reservation stays in 0003's spec, which works, and is linked.
- **Tests for the existing behavior too** (Q6, 2026-11-24): `ticket.sh` has none today, and the runner depends on it. The main cases (checks 17 to 22), not the two-agent race.
- **No new syntax for "Blocked by"** (2026-11-24): titles, separated by `; `, as the rows write them today, so every existing row reads correctly.
- **A linked blocker row matches only when the link starts the Item cell** (the builder, 2026-11-25): "Reading the blockers" says the match is the one `refine-ticket` step 9 uses, and that one is `index(x, "[" t "](") == 1`. Every linked row starts with its link.
- **`refine-ticket` step 9.1 also stops for an empty entry** (the builder, 2026-11-25): the doc's rule for the skill stops for an unknown blocker, and "Reading the blockers" counts an empty entry as one. The skill's per-title loop can't see an empty entry, so the step says it in words.

## Delivery and review

Built on branch `0008-ready-before-blockers`, claimed by the runner (`runner-49e67a9555ee`, claim `faedb9c9`), by Claude Code (claude-opus-5-5) as the runner's agent: the runner's first real run by hand, 0007's check 9.

**Acceptance checks:**
- 1 to 14 and 17 to 22: `scripts/test/ticket.test.sh` prints `ok N` for each, through `npm run test:scripts`, run by hand, in the pre-commit hook, and by the runner's checks. To see that they test something, `waiting_on()` was made to return at once for one run: checks 1, 3 to 8, 10, 11, 13, and 14 failed, and the rest, which don't depend on blockers being read, passed.
- 15: `scripts/test/agent-run.test.sh`'s check 1 has the waiting case: a run logs `no ready ticket`, exits 0, calls `claude` 0 times, makes no claim branch, and doesn't reach `claim next` (no `installing the clone's dependencies` in its log).
- 16: by reading: `.agents/skills/refine-ticket/SKILL.md` steps 8 and 9.1, in this PR's diff.

**What changed from the version marked ready:**
- `claim`'s and `list`'s message for a failed read of a built list is `couldn't read docs/tickets/README.md on origin/main, so the blockers of <slug> can't be checked` (or the same for `docs/README.md`): it starts with the text check 10 names, and says why it was read.
- The runner's waiting case is part of `agent-run.test.sh`'s check 1, not a check of its own, so 0007's numbering stays: it's 0007's "no ticket" check with another kind of no free ticket.
- The two decisions above, by the builder.
- `AGENTS.md`'s line for `scripts/ticket.sh` now links the spec doc, which the implementation map didn't list.
- The new spec doc has one known gap more than this doc: a blocker added after a claim's check on `main` isn't noticed, since nothing checks again.

**Not changed, for the owner:** the comment above CI's `scripts` job in `.github/workflows/ci.yml` still says the job runs the runner's tests only. It now runs `ticket.test.sh` too, through `npm run test:scripts`, with no change to the workflow. The runner's App can't push workflow changes, so that comment is left for a PR by the owner.

**Review:** (filled in once the PR has been reviewed)

**Rules, skills, and reviewers' context:** nothing to change found while building it.
