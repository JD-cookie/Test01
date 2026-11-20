# Keep the spec separate from the ticket history

Status: **designed**. When the user marks it `ready`, it gets a number and this doc is renamed `NNN-spec-and-tickets.md`. It moves to `docs/tickets/` in the PR that builds it, the first to follow the layout it sets up.

## Summary

`docs/` is meant to be the spec of the system: enough to rebuild it from the docs alone (`docs/README.md`, rule 3). Today the spec and the history of how it was built are the same files. A ticket's design doc moves to `docs/features/NNN-<slug>.md` when it's built, and keeps its "Readiness review", "Decisions made for this ticket", and "Delivery and review" sections, which record history. Two problems follow:
- **Changes to an existing feature have no clear home.** A ticket that changes accounts, like ticket 004 ("Delete expired session rows"), would move its own doc into `docs/features/` as a second doc about accounts. To know what the system does now, a reader would have to read every doc about it, in order.
- **The spec is mixed with history.** In feature 003, "Decisions" and "Delivery and review" are about 65 of its 249 lines. A rebuilder reads past them.

This ticket splits the two:
- **The spec docs are the living spec:** `docs/README.md`, `docs/devops.md`, and one doc per capability in `docs/features/`, always describing what's true now. A ticket that changes a capability edits its doc in place. A new doc is added only for a new capability.
- **`docs/tickets/` is the history.** A ticket's doc moves there from `docs/backlog/` when it's built, updated to what was built, with its Readiness review and its Delivery and review, and is frozen once its PR merges.
- **Spec docs are never renamed or deleted,** so links to them keep working: from ticket docs, which aren't edited, and from release-please's changelogs, which can't be edited by hand (rule 4). A removed capability's doc becomes a short stub.
- **They link both ways.** Each spec doc has a "Changes" list of the tickets that changed it, and each ticket doc names the spec docs it changed.

It's for whoever rebuilds or changes the system, people and agents, who need one place that says what it does now, and for the user, who wants the history kept too. The user chose the name `docs/tickets/` (2026-11-19), over `docs/changelog/`, which would clash with release-please's changelogs (rule 4), and `docs/changes/`.

What doesn't change: ticket numbers, branch names (`NNN-<slug>`), the backlog's statuses, claims, and `scripts/ticket.sh`; and the app's and server's code.

### Out of scope

- Rewriting the content of features 001 and 002. They were written before tickets, and have no history sections to move.
- A link checker in CI. Acceptance check 3 runs one, by hand, in this PR.
- Splitting `docs/devops.md`.
- The `new` and `ready` ticket commands (their own backlog item). Its row is updated for the new paths.

## Concepts

- **Spec doc:** `docs/README.md`, `docs/devops.md`, or a doc in `docs/features/`. It describes what the system does now, and is updated in place by every change to that behavior. It's never renamed or deleted.
- **Ticket doc:** a ticket's design doc. It lives in `docs/backlog/` until the ticket is built, then in `docs/tickets/`, where it's a record of one change: how it was refined, what was built, and how it was checked. Its spec sections are a snapshot of that part of the spec as built, on the day its PR merged.
- **Frozen:** a ticket doc in `docs/tickets/` isn't edited after its PR merges, links included. Whatever happens later, such as a check that can only run after the merge, is recorded in a later ticket doc, which links back. A later ticket that changes the same behavior gets its own ticket doc, and edits the spec doc.
- **Stable link:** a link that can't break once its doc is frozen. From a ticket doc in `docs/tickets/`, a relative link may point only to a spec doc, by file only, never to a section (`#…`), since headings change; or to another doc in `docs/tickets/`, with or without a section, since both are frozen. Anything else, such as a design doc still in `docs/backlog/`, a skill, or code, is linked as a GitHub permalink at a commit on `main`: `https://github.com/JD-cookie/Test01/blob/<sha>/<path>`, with an optional `#…`. Code paths given as plain text, as in an implementation map, aren't links.

## User-facing behavior

The "users" are people and agents writing and reading docs.

### Building a ticket (`next-ticket` step 2, and the backlog's "How it works")

In the ticket's PR:
1. `git mv docs/backlog/NNN-<slug>.md docs/tickets/NNN-<slug>.md`, and update its spec sections to match what was built, as `next-ticket` does today. The version that was marked ready stays in git, in the ready PR. Its status line says built, with the date. It gets a **Delivery and review** section, as today, which also says what changed from the ready version and why, and a **Spec docs changed** line, after the status line, linking each spec doc it changed.
2. **Make its links stable** (see "Concepts"): drop the section from each link to a spec doc, and turn each link to anything else outside `docs/tickets/` into a permalink at the commit the branch started from (`git merge-base origin/main HEAD`). For ticket 004 today, that's `../features/001-accounts.md#data-model` → `../features/001-accounts.md`, and `../devops.md#environments` → `../devops.md`.
3. **The spec:** for a new capability, write `docs/features/NNN-<slug>.md`, with the same number as the ticket, from the ticket's spec sections as built, and add it to the Features table in `docs/README.md`. For a change to an existing capability, edit its doc in place. Operational changes go in `docs/devops.md`, as now. A ticket can do both.
4. **Changes lists:** each spec doc it changed gets a line at the end of its **Changes** section: `- NNN: <title> ([ticket](<path>))`. The path is relative to the spec doc: `../tickets/NNN-<slug>.md` from `docs/features/`, and `tickets/NNN-<slug>.md` from `docs/README.md` and `docs/devops.md`.
5. **The index:** add a row to `docs/tickets/README.md`: `| NNN | [<title>](NNN-<slug>.md) | #<PR> | <spec docs changed, linked> |`, with columns `#`, `Ticket`, `PR`, `Spec docs changed`. The PR number is known once the PR is open: the builder adds it in a commit after opening it.
6. Delete the ticket's row from the backlog, and fix links to the old path everywhere outside `docs/tickets/`.

A link elsewhere to a ticket that's still in `docs/backlog/` breaks when that ticket is built: step 6 fixes it, except in frozen ticket docs, which is why step 2 makes them stable.

### Writing a spec doc (`docs/README.md`, "Writing a feature doc")

The section is split in two:
- **A spec doc's sections:** 1 to 7 of today's list (summary and concepts, behavior, API, data model, security and configuration, implementation map, acceptance checks), plus **Changes** at the end. A spec doc has no decisions section: the reasons are in the ticket docs its Changes list links. `docs/README.md` and `docs/devops.md` keep their own structure, and get a Changes section at the end too.
- **A ticket doc's sections:** the same spec sections, plus "Readiness review", "Decisions made for this ticket", and "Delivery and review", the Spec docs changed line, and the stable-link rule.

It also says that a spec doc is never renamed or deleted. When a ticket removes a capability, its spec doc is cut to a stub: the title, `Status: removed`, the date, the ticket that removed it, and its Changes list. When a spec doc's content moves into another, as for a ticket built under the old layout (see "Processing"), it's cut to a stub the same way, with `Status: merged into <spec doc>`, linked. Its number stays used either way.

### Numbers

A ticket's number is still one more than the highest used. That now includes `docs/tickets/` as well as `docs/features/`, the backlog table, and the `NNN-*` and `ready-NNN` branches: refine-ticket step 9.1's command, and step 9.5's "taken on main" check, look in both folders. A ticket that changes an existing capability adds no file to `docs/features/`, so that folder's numbers get gaps.

### When is a blocking item built?

refine-ticket step 9.1 checks that every item in a row's "Blocked by: …" is built before marking it `ready`. Today that means its row is gone from the backlog and it's in the Features table of `docs/README.md`, which a ticket that changes an existing capability, or this one, never joins. From now on: its row is gone from the backlog, and it's in `docs/tickets/README.md`; or, for features built before the backlog (001 and 002), in the Features table.

### "Already built?"

refine-ticket step 3 searches the code, `docs/features/`, and `docs/tickets/`.

## Processing

### What changes in this ticket's own PR

- **Feature 003's spec** stays in `docs/features/003-refine-ticket-skill.md`, updated to match the changed skill: the status line (no "see Delivery and review"), step 3's search, step 9's number sources and its "Blocked by" check, the Readiness review section's description where it mentions the layout, and the implementation map. It gets a Changes section: `- 003: A skill that gets a ticket ready to build ([ticket](../tickets/003-refine-ticket-skill.md))`, then a line for this ticket.
- **Ticket 003's doc**, `docs/tickets/003-refine-ticket-skill.md` (new): a title, a status line (built 2026-11-18 in PR #10, its last checks recorded in PR #12), a Spec docs changed line (`003-refine-ticket-skill.md`), and 003's "Decisions made for this ticket" and "Delivery and review", moved. Two changes in the move, made before it's frozen: its links are made stable (step 2 above; the link to `../backlog/004-delete-expired-sessions.md#readiness-review` becomes a permalink); and the note that check 2's new review rules are pending gets its result, which this ticket's own refinement shows (two reviewers in every round): it links this ticket's doc, `NNN-spec-and-tickets.md#readiness-review`. 003 was built before this layout, so its ticket doc has no spec sections of its own: it says the spec as built is in git at 41516db.
- **Features 001 and 002:** each gets a Changes section, with a first line saying it was built before the backlog (001 in commit d5f3a9a, 002 in PR #1), then a line for this ticket. They get no ticket docs.
- **`docs/README.md` and `docs/devops.md`:** a Changes section, with a line for this ticket in `docs/README.md` (devops.md doesn't change otherwise, so its section starts empty: "None yet.").
- **The index**, `docs/tickets/README.md` (new), with a line saying what the folder holds, and rows for 003 (PR #10) and this ticket.
- **Status lines** of the docs still in `docs/backlog/` that say "It moves to `docs/features/` in the PR that builds it": 004, `server-container-image.md`, and the runner's three parts if PR #13 has merged by then (if it hasn't, PR #13 is updated instead). Each says it moves to `docs/tickets/`, and which spec docs it changes where that's known (004: `001-accounts.md`).
- **This ticket's own doc** goes to `docs/tickets/NNN-spec-and-tickets.md`. It's a change to how the docs work, not a capability of the system, so it adds no file to `docs/features/`. Its Spec docs changed line lists `docs/README.md`, `001-accounts.md`, `002-rate-limiting.md`, and `003-refine-ticket-skill.md`, and each of those gets its line in Changes.

### If a ticket is built under the old layout first

Ticket 004 is `ready` now, and could be built before this one. The plan builds this first (004 is kept for Day 4's run, after the runner's three parts), but if 004, or another ticket, reaches `main` first with its doc in `docs/features/`, this ticket's PR converts it too (Q7): its spec content goes into the spec doc it changed (004: `001-accounts.md`), its doc moves to `docs/tickets/` like 003's, and its file in `docs/features/` stays, as a stub that says it was merged into that spec doc, since spec docs are never deleted.

## Security and configuration

No code, settings, secrets, or workflows change.

Rules: rule 3 changes. Its **rule** says the spec docs are `docs/README.md`, `docs/devops.md`, and `docs/features/`, updated in place in the PR that changes the behavior; a built ticket's doc goes to `docs/tickets/`, with stable links, and is frozen once its PR merges; and a spec doc is never renamed or deleted. Its **Applies to** keeps the exemption for docs-only, test-only, and release PRs from the requirement to update the spec, but says the other three hold for every PR, docs-only ones included, since those are the ones most likely to rename a doc or edit a frozen one. Rule 4: `server/CHANGELOG.md` and `app/CHANGELOG.md` link `docs/features/001-accounts.md`, and can't be edited by hand, so spec docs keep their names. The other rules are unaffected.

Failure modes: a ticket PR that forgets the spec update leaves the spec stale. A renamed or deleted spec doc, or an unstable link in a ticket doc, would break links from frozen docs: rule 3 forbids both, reviewers and Qodo check rule 3, and acceptance check 3's link check finds them once. Known gap: nothing checks it automatically after this PR.

## Implementation map

- `AGENTS.md`: rule 3, as in "Security and configuration"; the path table (a `docs/tickets/` row); and "Backlog tickets" ("One ticket per branch and PR").
- `docs/README.md`: the intro (spec and history), "Features", "Writing a feature doc" split into spec docs and ticket docs, the line on where a design doc moves ("from `backlog/` into `features/`"), and a Changes section.
- `docs/devops.md`: a Changes section.
- `docs/backlog/README.md`: "How it works" (marking ready: the number sources; building it: the six steps above), and the `new` and `ready` commands' row.
- `.agents/skills/next-ticket/SKILL.md`: step 2 (the six steps above), and the PR body's first line (`Ticket: NNN-slug (docs/tickets/NNN-slug.md)`).
- `.agents/skills/refine-ticket/SKILL.md`: step 3 ("Already built?"), step 9.1 (the number sources and the "Blocked by" check), and step 9.5 ("taken on main").
- `docs/features/001-accounts.md`, `002-rate-limiting.md`: Changes sections.
- `docs/features/003-refine-ticket-skill.md`: the spec updates and Changes section listed in "Processing"; its history sections removed.
- `docs/tickets/003-refine-ticket-skill.md` and `docs/tickets/README.md` (new).
- The status lines listed in "Processing".

## Acceptance checks

Checks 1 to 4 are run by the builder, in this PR, with their commands and output in "Delivery and review".

1. **Numbers and blockers:** in a scratch clone with a local bare `origin`:
   - with `docs/tickets/007-x.md` on `main` and nothing higher anywhere else, refine-ticket step 9.1's command prints `008`, and step 9.5's check prints `taken on main` for `007`
   - an item whose Notes say "Blocked by: X", where X's row is gone and X is in `docs/tickets/README.md` but not in the Features table, passes step 9.1's check; with X's row still in the backlog, it doesn't
2. **No stale paths:** `grep -rnE "features/" AGENTS.md docs .agents --include=*.md`, outside `docs/tickets/`, lists no instruction that moves a ticket's doc into `features/`, in either spelling (`docs/features/` or `features/`). Each remaining hit is a link to a spec doc or a number source, and the list goes in "Delivery and review".
3. **Links:** every relative link in `docs/`, `AGENTS.md`, and `.agents/` resolves to a file, and to a heading where it has a `#…`; every link in `docs/tickets/` is stable (see "Concepts"); and every permalink's commit and path exist (`git cat-file -e <sha>:<path>`). Checked with a script in a scratch directory, which prints each broken or unstable link, and prints nothing for this PR.
4. **The conversion:** `docs/features/003-refine-ticket-skill.md` has no "Decisions made for this ticket" or "Delivery and review" section, and `docs/tickets/003-refine-ticket-skill.md` has both: `git diff --color-moved` shows them moved, apart from the two changes named in "Processing". 003's spec names `docs/tickets/` in step 3 and step 9, as the skill does. Each of the four spec docs this ticket changed has a Changes line for it, and its Spec docs changed line lists all four.
5. **This ticket's own PR follows the new layout:** its doc is in `docs/tickets/`, it adds no file to `docs/features/`, and the index has its row with the PR number.
6. **The next build follows it:** the next ticket built after this one (likely the runner's part 1) moves its doc to `docs/tickets/` and updates its spec docs in place. That ticket's own "Delivery and review" records it, with a link back to this ticket's doc: this one is frozen by then.

## Readiness review

Refined 2026-11-19 by Claude Code (claude-opus-5-5).

- **Goal, restated:** for people and agents who rebuild or change the system: one place that says what it does now, separate from how each change was made. The smallest change: `docs/features/` as the living spec, edited in place; built ticket docs in `docs/tickets/`, frozen; links both ways.
- **Is it needed:** not built (`docs/`, `AGENTS.md`, `.agents/skills/` all move a built ticket's doc to `docs/features/`). Overlaps: PR #13's three runner docs and ticket 004 say their doc moves to `docs/features/`; this ticket updates those lines, or PR #13 is updated if it merges later. The `new` and `ready` commands row names `docs/features/` too. Dropped before: no (`git log -p --follow -- docs/backlog/README.md`, commit messages).
- **Definition of Ready** (before review round 1): 1 pass (Summary: who, what changes, what doesn't); 2 pass (see "Is it needed"); 3 pass (Out of scope); 4 pass (docs and skills, one PR); 5 pass (every path, section, line format, and moved section named); 6 not applicable (nothing for the user to set up; the user merges as always); 7 pass (six checks, each with where and what shows it passed; check 6 after the merge); 8 pass (rule 3 changes, rule 4 kept); 9 pass (no code or secrets; the failure modes and the known gap); 10 pass (Q1 to Q7 answered)
- **Questions and answers:**
  - Folder name → `docs/tickets/` (the user's choice, over `docs/changelog/` and `docs/changes/`).
  - Q1: a built ticket's doc keeps its design as marked ready? → no: updated to as implemented, then frozen (the user's counter-proposal, accepted).
  - Q2: decisions only in ticket docs → yes.
  - Q3: only a new capability gets a spec doc, with its ticket's number → yes, "improved by never deleting a spec doc".
  - Q4: an index, `docs/tickets/README.md` → yes.
  - Q5: this PR converts 003 and gives 001 and 002 Changes lists → yes.
  - Q6 (from the user's point that frozen tickets' links could break): spec docs never renamed or deleted, and no section links from ticket docs → yes.
  - Q7 (after review round 1): if 004 or another ticket is built under the old layout first, this PR converts it, and its file in `docs/features/` stays as a stub saying it was merged into the spec doc it changed → yes (2026-11-19).
- **Review round 1:** Codex (gpt-6.1-sol) and opencode (ollama-cloud/kimi-k3.1-pro), run separately. Both restatements match. 16 findings (Codex 7, opencode 9); 6 found by both, so 10 in all. All checked against the files and kept; none dropped.
  - Both (blocking): check 6 edited this ticket's doc after its merge, which "Frozen" forbids, and 003's note says a later result "goes here". Fixed: later results go in the later ticket's doc, which links back; 003's note gets its result before the move (this ticket's own refinement).
  - Both (blocking): 003's history links `../backlog/004-delete-expired-sessions.md#readiness-review`, which breaks when 004 is built, and frozen docs can't be fixed. Fixed: the stable-link rule (spec docs by file, other ticket docs, permalinks for the rest), applied when a ticket doc moves (step 2).
  - Both (blocking): refine-ticket step 9.1's "Blocked by" check needs the item in the Features table, which this ticket and any ticket changing an existing capability never join. Fixed: built means listed in `docs/tickets/README.md` (or, for 001 and 002, the Features table); check 1 tests it.
  - Both (blocking): 003's spec would still describe the old number sources and search (`003-refine-ticket-skill.md:37`, `:84`). Fixed: the 003 updates are listed, and check 4 tests them.
  - Both (blocking): 004 is `ready` and could be built first, leaving a second accounts doc. Fixed as far as the doc goes: "If a ticket is built under the old layout first"; the stub is Q7.
  - Both (blocking): rule 3 exempts docs-only PRs, the likeliest to rename a spec doc or edit a frozen one. Fixed: the new invariants hold for every PR; only the spec-update requirement keeps the exemption.
  - Codex (minor): the Changes line's `../tickets/` path is wrong from `docs/README.md` and `docs/devops.md`. Fixed: the path per location.
  - opencode (blocking): this ticket's Spec docs changed line left out 001 and 002, which it edits. Fixed: all four spec docs, each with a Changes line; check 4.
  - opencode (blocking): the no-section rule was only on one line of the build step, and 004 links `001-accounts.md#data-model` and `devops.md#environments`. Fixed: the stable-link rule in "Concepts", in `docs/README.md`, and in the build step, with 004 as the example; check 3 covers every link in `docs/tickets/`.
  - opencode (minor): check 2 grepped only `docs/features/`, missing `docs/README.md:42`'s "into `features/`". Fixed: both spellings, with the remaining hits listed.

## Decisions made for this ticket

- **The folder is `docs/tickets/`** (the user, 2026-11-19): it says what's in it. `docs/changelog/` would clash with release-please's `CHANGELOG.md` files and rule 4; `docs/changes/` was the other option.
- **Spec docs are never renamed or deleted** (Q6, the user, 2026-11-19). A removed capability's doc becomes a stub. Links from frozen ticket docs and from the release changelogs, which can't be edited, then keep working. The other option, letting ticket docs be edited for link fixes only, would weaken "history isn't edited" and wouldn't help the changelogs. Ticket docs link spec docs by file, never by section, since headings change.
- **A built ticket's doc is updated to what was built, then frozen** (Q1, the user, 2026-11-19). It's a snapshot of that part of the spec on the day it merged. The version marked ready stays in git, and "Delivery and review" says what changed from it.
- **Decisions live only in ticket docs** (Q2, the user, 2026-11-19). The spec doc stays lean, and its Changes list links the ticket docs, where the reasons are.
- **Only a new capability gets a spec doc,** with its ticket's number (Q3, the user, 2026-11-19). A spec doc per ticket would bring back several docs per capability. `docs/features/`'s numbers get gaps. Never deleting a spec doc means a number, once used there, stays used.
- **An index, `docs/tickets/README.md`** (Q4, the user, 2026-11-19): one row per built ticket, with its PR and the spec docs it changed.
- **This PR converts 003, and gives 001 and 002 Changes lists** (Q5, the user, 2026-11-19), so every spec doc follows the layout from the start.
- **A ticket built under the old layout first is converted by this PR** (Q7, the user, 2026-11-19): its spec goes into the spec doc it changed, its doc moves to `docs/tickets/`, and its file in `docs/features/` stays as a `merged into` stub, since spec docs are never deleted. The plan builds this ticket before 004, so it's only a fallback.
