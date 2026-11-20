# Keep the spec separate from the ticket history

Status: **designed**. When the user marks it `ready`, it gets a number and this doc is renamed `NNN-spec-and-tickets.md`. It moves to `docs/tickets/` in the PR that builds it, the first to follow the layout it sets up.

## Summary

`docs/` is meant to be the spec of the system: enough to rebuild it from the docs alone (`docs/README.md`, rule 3). Today the spec and the history of how it was built are the same files. A ticket's design doc moves to `docs/features/NNN-<slug>.md` when it's built, and keeps its "Readiness review", "Decisions made for this ticket", and "Delivery and review" sections, which record history. Two problems follow:
- **Changes to an existing feature have no clear home.** A ticket that changes accounts, like ticket 004 ("Delete expired session rows"), would move its own doc into `docs/features/` as a second doc about accounts. To know what the system does now, a reader would have to read every doc about it, in order.
- **The spec is mixed with history.** In feature 003, "Decisions" and "Delivery and review" are about 65 of its 249 lines. A rebuilder reads past them.

This ticket splits the two:
- **`docs/features/` is the living spec.** One doc per capability, always describing what's true now. A ticket that changes a capability edits its doc in place. A new doc is added only for a new capability.
- **`docs/tickets/` is the history.** A ticket's doc moves there from `docs/backlog/` when it's built, updated to what was built, with its Readiness review and its Delivery and review, and isn't edited after its PR merges.
- **Spec docs are never renamed or deleted,** so links to them keep working: from ticket docs, which aren't edited, and from release-please's changelogs, which can't be edited by hand (rule 4). A removed capability's doc becomes a short stub.
- **They link both ways.** Each spec doc has a "Changes" list of the tickets that shaped it, and each ticket doc names the spec docs it changed.

It's for whoever rebuilds or changes the system, people and agents, who need one place that says what it does now, and for the user, who wants the history kept too. The user chose the name `docs/tickets/` (2026-11-19), over `docs/changelog/`, which would clash with release-please's changelogs (rule 4), and `docs/changes/`.

What doesn't change: ticket numbers, branch names (`NNN-<slug>`), the backlog's statuses, claims, and `scripts/ticket.sh`; `docs/devops.md`, which is already a living doc; and the app's and server's code.

### Out of scope

- Rewriting the content of features 001 and 002. They were written before tickets, and have no history sections to move.
- A link checker in CI. Acceptance check 3 runs one once, by hand.
- Splitting `docs/devops.md`.
- The `new` and `ready` ticket commands (their own backlog item). Its row is updated for the new paths.

## Concepts

- **Spec doc:** a doc in `docs/features/`, or `docs/devops.md`, that describes what the system does now. It's updated in place by every change to that behavior.
- **Ticket doc:** a ticket's design doc. It lives in `docs/backlog/` until the ticket is built, then in `docs/tickets/`, where it's a record of one change: how it was refined, what was built, and how it was checked. Its spec sections are a snapshot of that part of the spec as built, on the day its PR merged.
- **Frozen:** a ticket doc in `docs/tickets/` isn't edited after its PR merges, links included. A later ticket that changes the same behavior gets its own ticket doc, and edits the spec doc.

## User-facing behavior

The "users" are people and agents writing and reading docs.

### Building a ticket (`next-ticket`, and the backlog's "How it works")

In the ticket's PR:
1. `git mv docs/backlog/NNN-<slug>.md docs/tickets/NNN-<slug>.md`, and update its spec sections to match what was built, as `next-ticket` does today. The version that was marked ready stays in git, in the ready PR. Its status line says built, with the date. It gets a **Delivery and review** section, as today, which also says what changed from the ready version and why, and a **Spec docs changed** line linking each spec doc it changed, by file only, never to a section (`#…`): headings change, files don't.
2. **The spec:** for a new capability, write `docs/features/NNN-<slug>.md`, with the same number as the ticket, from the ticket's spec sections as built, and add it to the Features table in `docs/README.md`. For a change to an existing capability, edit its doc in place. Operational changes go in `docs/devops.md`, as now. A ticket can do both.
3. Each spec doc it touched gets a line in its **Changes** list: `- NNN: <title> ([ticket](../tickets/NNN-<slug>.md))`.
4. Add a row for the ticket to the index, `docs/tickets/README.md`: `| NNN | [<title>](NNN-<slug>.md) | #<PR> | <spec docs changed, linked> |`, with columns `#`, `Ticket`, `PR`, `Spec docs changed`. Then delete its row from the backlog, and fix links to the old path, outside `docs/tickets/`. The PR number is known once the PR is open: the builder adds it in a commit after opening it.

### Writing a spec doc (`docs/README.md`, "Writing a feature doc")

The section is split in two: the spec doc's sections (1 to 7 of today's list: summary and concepts, behavior, API, data model, security and configuration, implementation map, acceptance checks, plus "Changes"), and the ticket doc's (the same spec sections, plus "Readiness review", "Decisions made for this ticket", and "Delivery and review"). A spec doc has no decisions section: the reasons are in the ticket docs its Changes list links.

It also says that a spec doc is never renamed or deleted. When a ticket removes a capability, its spec doc is cut to a stub: the title, `Status: removed`, the date, the ticket that removed it, and its Changes list. Its number stays used.

### Numbers

A ticket's number is still one more than the highest used. That now includes `docs/tickets/` as well as `docs/features/`, the backlog table, and the `NNN-*` and `ready-NNN` branches. A ticket that changes an existing capability adds no file to `docs/features/`, so that folder's numbers get gaps.

## Processing

### What moves in this ticket's own PR

- **Feature 003:** its spec stays in `docs/features/003-refine-ticket-skill.md`. Its "Decisions made for this ticket" and "Delivery and review" move, unchanged, to `docs/tickets/003-refine-ticket-skill.md`, with a title, a status line, and a Spec docs changed line, and the spec gets a Changes list linking it. 003 was built before this layout, so its ticket doc has no spec sections of its own: it says the spec as built is in the spec doc's git history at 41516db (PR #10).
- **Features 001 and 002:** each gets a Changes list saying it was built before the backlog: 001 in commit d5f3a9a, 002 in PR #1. They get no ticket docs.
- **The index**, `docs/tickets/README.md`, with rows for 003 (PR #10) and for this ticket.
- **Status lines** of the docs still in `docs/backlog/` that say "It moves to `docs/features/` in the PR that builds it": 004, `server-container-image.md`, and the runner's three parts if PR #13 has merged by then (if it hasn't, PR #13 is updated instead). Each says it moves to `docs/tickets/`, and which spec docs it changes where that's known (004: `001-accounts.md`).
- **This ticket's own doc** goes to `docs/tickets/NNN-spec-and-tickets.md`. It's a change to how the docs work, not a capability of the system, so it adds no spec doc. Its Spec docs changed line lists `docs/README.md` and `003-refine-ticket-skill.md`.

## Security and configuration

No code, settings, secrets, or workflows change. Rules: rule 3's wording changes (below); the others are unaffected. Rule 4: `server/CHANGELOG.md` and `app/CHANGELOG.md` link `docs/features/001-accounts.md`, and can't be edited by hand, so spec docs keep their names.

Failure modes: a ticket PR that forgets the spec update leaves the spec stale. A renamed or deleted spec doc would break links from frozen ticket docs and the changelogs: rule 3 forbids it, and acceptance check 3's link check finds it. Qodo and the reviewers check rule 3, which says so. Known gap: nothing checks it automatically.

## Implementation map

- `AGENTS.md`: rule 3 (the spec is `docs/features/` and `docs/devops.md`, updated in place, and a spec doc is never renamed or deleted; a ticket's doc goes to `docs/tickets/`, and is frozen once its PR merges), the path table, and "Backlog tickets" ("One ticket per branch and PR").
- `docs/README.md`: the intro (spec and history), "Features", "Writing a feature doc" split into spec docs and ticket docs.
- `docs/backlog/README.md`: "How it works" (marking ready: the number; building it), and the `new` and `ready` commands' row.
- `.agents/skills/next-ticket/SKILL.md`: step 2 and the PR body's first line (`Ticket: NNN-slug (docs/tickets/NNN-slug.md)`).
- `.agents/skills/refine-ticket/SKILL.md`: step 3 ("Already built?" searches `docs/features/` and `docs/tickets/`), and step 9's two number checks (`docs/tickets/` added).
- `docs/features/001-accounts.md`, `002-rate-limiting.md`, `003-refine-ticket-skill.md`: Changes lists; 003 loses its history sections.
- `docs/tickets/003-refine-ticket-skill.md` and `docs/tickets/README.md` (new).
- The status lines listed in "Processing".

## Acceptance checks

1. **Numbers:** in a scratch clone with a local bare `origin`, with a file `docs/tickets/007-x.md` on `main` and nothing higher anywhere else, refine-ticket step 9.1's command prints `008`, and step 9.5's check prints `taken on main` for `007`. Recorded in "Delivery and review".
2. **No stale paths:** `grep -rn "docs/features/" AGENTS.md docs .agents --include=*.md` shows no instruction that moves a ticket's doc to `docs/features/`, outside `docs/tickets/` (history isn't edited).
3. **Links:** every relative link in `docs/`, `AGENTS.md`, and `.agents/` resolves to a file (and an anchor, where it has one), checked once with a script in a scratch directory, and no link from `docs/tickets/` to `docs/features/` has an anchor. The output, with no broken links, goes in "Delivery and review".
4. **Feature 003:** `docs/features/003-refine-ticket-skill.md` has no "Decisions made for this ticket" or "Delivery and review" section, and `docs/tickets/003-refine-ticket-skill.md` has both, unchanged in content (`git diff --color-moved` shows them as moved).
5. **This ticket's own PR follows the new layout:** its doc is in `docs/tickets/`, and it adds no spec doc.
6. **The next build follows it:** the next ticket built after this one (likely 004 or part 1 of the runner) moves its doc to `docs/tickets/` and updates its spec docs in place. Recorded afterwards, in a follow-up to this ticket's "Delivery and review", as ticket 003's last checks were in PR #12.

## Readiness review

Refined 2026-11-19 by Claude Code (claude-opus-5-5).

- **Goal, restated:** for people and agents who rebuild or change the system: one place that says what it does now, separate from how each change was made. The smallest change: `docs/features/` as the living spec, edited in place; built ticket docs in `docs/tickets/`, frozen; links both ways.
- **Is it needed:** not built (`docs/`, `AGENTS.md`, `.agents/skills/` all move a built ticket's doc to `docs/features/`). Overlaps: PR #13's three runner docs and ticket 004 say their doc moves to `docs/features/`; this ticket updates those lines, or PR #13 is updated if it merges later. The `new` and `ready` commands row names `docs/features/` too. Dropped before: no (`git log -p --follow -- docs/backlog/README.md`, commit messages).
- **Definition of Ready** (before review round 1): 1 pass (Summary: who, what changes, what doesn't); 2 pass (see "Is it needed"); 3 pass (Out of scope); 4 pass (docs and skills, one PR); 5 pass (every path, section, line format, and moved section named); 6 not applicable (nothing for the user to set up; the user merges as always); 7 pass (six checks, each with where and what shows it passed; check 6 after the merge); 8 pass (rule 3 changes, rule 4 kept); 9 pass (no code or secrets; the failure modes and the known gap); 10 pass (Q1 to Q6 answered)
- **Questions and answers:**
  - Folder name → `docs/tickets/` (the user's choice, over `docs/changelog/` and `docs/changes/`).
  - Q1: a built ticket's doc keeps its design as marked ready? → no: updated to as implemented, then frozen (the user's counter-proposal, accepted).
  - Q2: decisions only in ticket docs → yes.
  - Q3: only a new capability gets a spec doc, with its ticket's number → yes, "improved by never deleting a spec doc".
  - Q4: an index, `docs/tickets/README.md` → yes.
  - Q5: this PR converts 003 and gives 001 and 002 Changes lists → yes.
  - Q6 (from the user's point that frozen tickets' links could break): spec docs never renamed or deleted, and no section links from ticket docs → yes.

## Decisions made for this ticket

- **The folder is `docs/tickets/`** (the user, 2026-11-19): it says what's in it. `docs/changelog/` would clash with release-please's `CHANGELOG.md` files and rule 4; `docs/changes/` was the other option.
- **Spec docs are never renamed or deleted** (Q6, the user, 2026-11-19). A removed capability's doc becomes a stub. Links from frozen ticket docs and from the release changelogs, which can't be edited, then keep working. The other option, letting ticket docs be edited for link fixes only, would weaken "history isn't edited" and wouldn't help the changelogs. Ticket docs link spec docs by file, never by section, since headings change.
- **A built ticket's doc is updated to what was built, then frozen** (Q1, the user, 2026-11-19). It's a snapshot of that part of the spec on the day it merged. The version marked ready stays in git, and "Delivery and review" says what changed from it.
- **Decisions live only in ticket docs** (Q2, the user, 2026-11-19). The spec doc stays lean, and its Changes list links the ticket docs, where the reasons are.
- **Only a new capability gets a spec doc,** with its ticket's number (Q3, the user, 2026-11-19). A spec doc per ticket would bring back several docs per capability. `docs/features/`'s numbers get gaps. Never deleting a spec doc means a number, once used there, stays used.
- **An index, `docs/tickets/README.md`** (Q4, the user, 2026-11-19): one row per built ticket, with its PR and the spec docs it changed.
- **This PR converts 003, and gives 001 and 002 Changes lists** (Q5, the user, 2026-11-19), so every spec doc follows the layout from the start.
