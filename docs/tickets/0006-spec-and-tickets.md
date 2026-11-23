# Keep the spec separate from the ticket history

Status: **built**, 2026-11-22, ticket 0006, the first ticket built in the layout it sets up. Marked ready on 2026-11-20 in PR #15.

Spec docs changed: [docs/README.md](../README.md), [docs/devops.md](../devops.md), [0001-accounts.md](../features/0001-accounts.md), [0002-rate-limiting.md](../features/0002-rate-limiting.md), [0003-refine-ticket-skill.md](../features/0003-refine-ticket-skill.md).

## Summary

`docs/` is meant to be the spec of the system: enough to rebuild it from the docs alone (`docs/README.md`, rule 3). Today the spec and the history of how it was built are the same files. A ticket's design doc moves to `docs/features/NNNN-<slug>.md` when it's built, and keeps its "Readiness review", "Decisions made for this ticket", and "Delivery and review" sections, which record history. Two problems follow:
- **Changes to an existing feature have no clear home.** A ticket that changes accounts, like ticket 0004 ("Delete expired session rows"), would move its own doc into `docs/features/` as a second doc about accounts. To know what the system does now, a reader would have to read every doc about it, in order.
- **The spec is mixed with history.** In feature 0003, "Decisions" and "Delivery and review" are about 65 of its 249 lines. A rebuilder reads past them.

This ticket splits the two:
- **The spec docs are the living spec:** `docs/README.md`, `docs/devops.md`, and one doc per capability in `docs/features/`, always describing what's true now. A ticket that changes a capability edits its doc in place. A new doc is added only for a new capability.
- **`docs/tickets/` is the history.** A ticket's doc moves there from `docs/backlog/` when it's built, updated to what was built, with its Readiness review and its Delivery and review, and is frozen once its PR merges.
- **Spec docs are never renamed or deleted** once the PR that adds them has merged, so links to them keep working: from ticket docs, which aren't edited, and from release-please's changelogs, which can't be edited by hand (rule 4). A removed capability's doc becomes a short stub.
- **They link both ways.** Each spec doc has a "Changes" list of the tickets that changed it, and each ticket doc names the spec docs it changed.

It's for whoever rebuilds or changes the system, people and agents, who need one place that says what it does now, and for the user, who wants the history kept too. The user chose the name `docs/tickets/` (2026-11-19), over `docs/changelog/`, which would clash with release-please's changelogs (rule 4), and `docs/changes/`.

What doesn't change: ticket numbers, branch names (`NNNN-<slug>`), the backlog's statuses, claims, and `scripts/ticket.sh`; and the app's and server's code.

### Out of scope

- Rewriting the content of features 0001 and 0002. They were written before tickets, and have no history sections to move.
- A link checker in CI. Acceptance check 3 runs one, by hand, in this PR.
- Splitting `docs/devops.md`.
- The `new` and `ready` ticket commands (their own backlog item). Its row is updated for the new paths.

## Concepts

- **Spec doc:** `docs/README.md`, `docs/devops.md`, or a doc in `docs/features/`. It describes what the system does now, and is updated in place by every change to that behavior. It's never renamed or deleted once the PR that adds it has merged; a design doc in `docs/backlog/` can be renamed until then.
- **Ticket doc:** a ticket's design doc. It lives in `docs/backlog/` until the ticket is built, then in `docs/tickets/`, where it's a record of one change: how it was refined, what was built, and how it was checked. Its spec sections are a snapshot of that part of the spec as built, on the day its PR merged.
- **Frozen:** a ticket doc in `docs/tickets/` isn't edited after its PR merges, links included. Whatever happens later, such as a check that can only run after the merge, is recorded in a later ticket doc, which links back. A later ticket that changes the same behavior gets its own ticket doc, and edits the spec doc.
- **Stable link:** a link that can't break once its doc is frozen. From a ticket doc in `docs/tickets/`, a relative link may point only to a spec doc, by file only, never to a section (`#…`), since headings change; or to another doc in `docs/tickets/`, with or without a section, since both are frozen. Anything else that's already on `main`, such as a design doc still in `docs/backlog/`, a skill, or code, is linked as a GitHub permalink: `https://github.com/JD-cookie/Test01/blob/<sha>/<path>`, with an optional `#…`. `<sha>` is the newest commit on `main` that has the file at that path, with the heading if the link has one. To find it, go through `git log --format=%H origin/main -- <path>` newest first: for a commit that has the file, take it if the link has no heading, or if `git show <commit>:<path>` has the heading; for a commit that deleted or moved the file, try its parent. If no commit on `main` has the heading, for example because the ticket's own PR adds it, drop the `#…`. A file that the ticket's own PR adds isn't on `main` yet, so it can't be a permalink: name it as plain text instead, as an implementation map does. Plain-text paths aren't links.

## User-facing behavior

The "users" are people and agents writing and reading docs.

### Building a ticket (`next-ticket` step 2, and the backlog's "How it works")

In the ticket's PR:
1. `git mv docs/backlog/NNNN-<slug>.md docs/tickets/NNNN-<slug>.md`, and update its spec sections to match what was built, as `next-ticket` does today. The version that was marked ready stays in git, in the ready PR. Its status line says built, with the date. It gets a **Delivery and review** section, as today, which also says what changed from the ready version and why, and a **Spec docs changed** line, after the status line, linking each spec doc it changed.
2. **Make its links stable** (see "Concepts"): drop the section from each link to a spec doc, and turn each link to anything else outside `docs/tickets/` into a permalink, with the commit chosen as in "Concepts", or into plain text for a file the PR adds. For ticket 0004 today, that's `../features/0001-accounts.md#data-model` → `../features/0001-accounts.md`, and `../devops.md#environments` → `../devops.md`.
3. **The spec:** for a new capability, write `docs/features/NNNN-<slug>.md`, with the same number as the ticket, from the ticket's spec sections as built, and add it to the Features table in `docs/README.md`. For a change to an existing capability, edit its doc in place. Operational changes go in `docs/devops.md`, as now. A ticket can do both.
4. **Changes lists:** each spec doc it changed gets a line at the end of its **Changes** section: `- NNNN: <title> ([ticket](<path>))`. The path is relative to the spec doc: `../tickets/NNNN-<slug>.md` from `docs/features/`, and `tickets/NNNN-<slug>.md` from `docs/README.md` and `docs/devops.md`.
5. **The index:** add a row to `docs/tickets/README.md`: `| NNNN | [<title>](NNNN-<slug>.md) | #<PR> | <spec docs changed, linked> |`, with columns `#`, `Ticket`, `PR`, `Spec docs changed`. The PR number is known once the PR is open: the builder adds it in a commit after opening it.
6. Delete the ticket's row from the backlog, and fix links to the old path everywhere outside `docs/tickets/`.

A link elsewhere to a ticket that's still in `docs/backlog/` breaks when that ticket is built: step 6 fixes it, except in frozen ticket docs, which is why step 2 makes them stable.

### Writing a spec doc (`docs/README.md`, "Writing a feature doc")

The section is split in two:
- **A spec doc's sections:** 1 to 7 of today's list (summary and concepts, behavior, API, data model, security and configuration, implementation map, acceptance checks), plus **Changes** at the end. A spec doc has no decisions section: the reasons are in the ticket docs its Changes list links. `docs/README.md` and `docs/devops.md` keep their own structure, and get a Changes section at the end too.
- **A ticket doc's sections:** the same spec sections, plus "Readiness review", "Decisions made for this ticket", and "Delivery and review", the Spec docs changed line, and the stable-link rule.

It also says that a spec doc is never renamed or deleted once the PR that adds it has merged; a design doc in `docs/backlog/` can be renamed until then. When a ticket removes a capability, its spec doc is cut to a stub: the title, `Status: removed`, the date, the ticket that removed it, and its Changes list. When a spec doc's content moves into another, it's cut to a stub the same way, with `Status: merged into <spec doc>`, linked. Its number stays used either way.

### Numbers

A ticket's number is still one more than the highest used. That now includes `docs/tickets/` as well as `docs/features/`, the backlog table, and the `NNNN-*` and `ready-NNNN` branches: refine-ticket step 9.1's command, and step 9.5's "taken on main" check, look in both folders. A ticket that changes an existing capability adds no file to `docs/features/`, so that folder's numbers get gaps.

### When is a blocking item built?

refine-ticket step 9.1 checks that every item in a row's "Blocked by: …" is built before marking it `ready`. Today that means its row is gone from the backlog and it's in the Features table of `docs/README.md`, which a ticket that changes an existing capability, or this one, never joins. From now on: its row is gone from the backlog, and it's in `docs/tickets/README.md`; or, for features built before the backlog (0001 and 0002), in the Features table.

### "Already built?"

refine-ticket step 3 searches the code, `docs/features/`, and `docs/tickets/`.

## Processing

### What changes in this ticket's own PR

- **Feature 0003's spec** stays in `docs/features/0003-refine-ticket-skill.md`, updated to match the changed skill: the status line (no "see Delivery and review"), step 3's search, step 9's number sources and its "Blocked by" check, the Readiness review section's description where it mentions the layout, and the implementation map. It gets a Changes section: `- 0003: A skill that gets a ticket ready to build ([ticket](../tickets/0003-refine-ticket-skill.md))`, then a line for this ticket.
- **Ticket 0003's doc**, `docs/tickets/0003-refine-ticket-skill.md` (new): a title, a status line (built 2026-11-18 in PR #10, its last checks recorded in PR #12), a Spec docs changed line (`0003-refine-ticket-skill.md` and `docs/README.md`), and 0003's "Decisions made for this ticket" and "Delivery and review", moved. Two changes in the move, made before it's frozen: its links are made stable (step 2 above; the link to `../backlog/0004-delete-expired-sessions.md#readiness-review` becomes a permalink); and the note that check 2's new review rules are pending gets its result, which this ticket's own refinement shows (two reviewers in every round): it links this ticket's doc, `0006-spec-and-tickets.md#readiness-review`. 0003 was built before this layout, so its ticket doc has no spec sections of its own: it says the spec as built is in git at 41516db.
- **Features 0001 and 0002:** each gets a Changes section, with a first line saying it was built before the backlog (0001 in commit d5f3a9a, 0002 in PR #1), then a line for this ticket. They get no ticket docs.
- **`docs/README.md` and `docs/devops.md`:** a Changes section each. `docs/README.md`'s has a line for 0003, which changed its item 9 of "Writing a feature doc" (`0003-refine-ticket-skill.md`'s implementation map), and one for this ticket. `docs/devops.md`'s has a first line saying changes before this ticket aren't listed (git has them), and one for this ticket.
- **The index**, `docs/tickets/README.md` (new), with a line saying what the folder holds, and rows for 0003 (PR #10) and this ticket.
- **Status lines** of the docs still in `docs/backlog/` that said "It moves to `docs/features/` in the PR that builds it": 0004 and `server-container-image.md`. Each says it moves to `docs/tickets/`, and which spec docs it changes (0004: `0001-accounts.md` and `docs/devops.md`; the container image: `docs/devops.md`). The runner's three parts already said so: PR #17, which merged first, was fitted to this layout.
- **This ticket's own doc** goes to `docs/tickets/0006-spec-and-tickets.md`. It's a change to how the docs work, not a capability of the system, so it adds no file to `docs/features/`. Its Spec docs changed line lists `docs/README.md`, `docs/devops.md`, `0001-accounts.md`, `0002-rate-limiting.md`, and `0003-refine-ticket-skill.md`, and each of those five gets its line in Changes.

### Tickets built under the old layout

0003 is the only ticket built under the old layout, and this PR converts it (above). No other is expected: the plan builds this ticket next, and 0004 is kept for Day 4's run, after the runner's three parts. Until this PR merges, the user starts no ticket builds; the user is the only one who starts agents (Q9).

If another ticket is claimed or built under the old steps anyway, so that a claim branch other than this one's is on `origin`, or a doc other than 0001's, 0002's, or 0003's is in `docs/features/`, the builder stops and asks the user. No conversion steps are written for that case: they'd be needed at most once, and the user decides then. Before asking for the merge, the builder runs `git ls-remote --heads origin 'refs/heads/[0-9][0-9][0-9][0-9]-*'` (none on 2026-11-20) and records its output in "Delivery and review": it lists only this ticket's own branch.

## Security and configuration

No code, settings, secrets, or workflows change.

Rules: rule 3 changes. Its **rule** says the spec docs are `docs/README.md`, `docs/devops.md`, and `docs/features/`, updated in place in the PR that changes the behavior; a built ticket's doc goes to `docs/tickets/`, with stable links, and is frozen once its PR merges; and a spec doc is never renamed or deleted once the PR that adds it has merged; a design doc in `docs/backlog/` can be renamed until then. Its **Applies to** keeps the exemption for docs-only, test-only, and release PRs from the requirement to update the spec, but says the other three hold for every PR, docs-only ones included, since those are the ones most likely to rename a doc or edit a frozen one. Rule 4: `server/CHANGELOG.md` and `app/CHANGELOG.md` link `docs/features/0001-accounts.md`, and can't be edited by hand, so spec docs keep their names. The other rules are unaffected.

Failure modes: a ticket PR that forgets the spec update leaves the spec stale. A renamed or deleted spec doc, or an unstable link in a ticket doc, would break links from frozen docs: rule 3 forbids both, reviewers and Qodo check rule 3, and acceptance check 3's link check finds them once. Known gap: nothing checks it automatically after this PR.

## Implementation map

- `AGENTS.md`: rule 3, as in "Security and configuration"; the path table (a `docs/tickets/` row); and "Backlog tickets" ("One ticket per branch and PR").
- `docs/README.md`: the intro (spec and history), "Features", "Writing a feature doc" split into spec docs and ticket docs, the line on where a design doc moves ("from `backlog/` into `features/`"), and a Changes section.
- `docs/devops.md`: a Changes section.
- `docs/backlog/README.md`: "How it works" (marking ready: the number sources; building it: the six steps above), and the `new` and `ready` commands' row.
- `.agents/skills/next-ticket/SKILL.md`: step 2 (the six steps above), and the PR body's first line (`Ticket: NNNN-slug (docs/tickets/NNNN-slug.md)`).
- `.agents/skills/refine-ticket/SKILL.md`: step 3 ("Already built?"), step 9.1 (the number sources and the "Blocked by" check), step 9.3 (fix links to the renamed doc outside `docs/tickets/` only: `grep -rn "$slug.md" docs AGENTS.md .agents --exclude-dir=tickets`; frozen docs keep their permalinks), and step 9.5 ("taken on main").
- `docs/features/0001-accounts.md`, `0002-rate-limiting.md`: Changes sections.
- `docs/features/0003-refine-ticket-skill.md`: the spec updates and Changes section listed in "Processing"; its history sections removed.
- `docs/tickets/0003-refine-ticket-skill.md` and `docs/tickets/README.md` (new).
- The status lines listed in "Processing".

## Acceptance checks

Checks 1 to 6 are run by the builder, in this PR, with their commands and output in "Delivery and review". The scripts named here were kept in a scratch directory, not committed.

1. **Numbers and blockers:** in a scratch clone with a local bare `origin`:
   - with `docs/tickets/0007-x.md` on `main` and nothing higher anywhere else, refine-ticket step 9.1's command prints `0008`, and step 9.5's check prints `taken on main` for `0007`
   - an item whose Notes say "Blocked by: X", where X's row is gone and X is in `docs/tickets/README.md` but not in the Features table, passes step 9.1's check; with X's row still in the backlog, it doesn't
2. **No stale paths:** `grep -rnE "features/" AGENTS.md docs .agents --include=*.md --exclude-dir=tickets` lists no instruction that moves a ticket's doc into `features/`, in either spelling (`docs/features/` or `features/`). The other hits are expected: links to spec docs, instructions to write or edit a spec doc there, and the number sources and search places in refine-ticket steps 3 and 9. The builder goes through every hit, and lists each with its kind in "Delivery and review".
3. **Links:** every relative link in `docs/`, `AGENTS.md`, and `.agents/` resolves to a file, and to a heading where it has a `#…`; every link in `docs/tickets/` is stable (see "Concepts"); and for every permalink, its commit is on `main` (`git merge-base --is-ancestor <sha> origin/main`), its path exists there (`git cat-file -e <sha>:<path>`), and its `#…`, if any, matches a heading in that blob. Checked with a script in a scratch directory, which prints each broken or unstable link, and prints nothing for this PR.
4. **The conversion:** `docs/features/0003-refine-ticket-skill.md` has no "Decisions made for this ticket" or "Delivery and review" section, and `docs/tickets/0003-refine-ticket-skill.md` has both: `git diff --color=always --color-moved=zebra origin/main...HEAD -- docs/features/0003-refine-ticket-skill.md docs/tickets/0003-refine-ticket-skill.md` shows both sections as moved lines, apart from the two changes named in "Processing" (the stable links, and the result of check 2's pending note), which show as changed lines. 0003's spec names `docs/tickets/` in step 3 and step 9, as the skill does. Each of the five spec docs this ticket changed, plus any its conversion of an old-layout ticket changed, has a Changes line for it, and its Spec docs changed line and index row list them all. `docs/README.md`'s Changes section has 0003's line, and 0003's ticket doc and index row list `docs/README.md`.
5. **Nothing left in the old layout:** after the last merge of `main`:
   - `git ls-remote` as in "Tickets built under the old layout" lists only this ticket's own branch
   - every file in `docs/features/` is a spec doc: `grep -lnE '^## (Readiness review|Decisions made for this ticket|Delivery and review)[[:space:]]*$' docs/features/*.md` prints nothing. The whole heading is matched, since 0003's spec keeps its "Readiness review section" heading (`0003-refine-ticket-skill.md:101`)
   - `git log origin/main --format= --name-only --no-renames --diff-filter=A -- docs/features | grep -oE '[0-9]{4}-[^/]+\.md$' | sort -u` lists every doc ever added to `docs/features/`, and prints exactly 0001, 0002, and 0003 (as on 2026-11-20)
6. **This ticket's own PR follows the new layout:** its doc is in `docs/tickets/`, it adds no file to `docs/features/`, and the index has its row with the PR number.
7. **The next build follows it:** the next ticket built after this one (likely the runner's part 1) moves its doc to `docs/tickets/` and updates its spec docs in place. That ticket's own "Delivery and review" records it, with a link back to this ticket's doc: this one is frozen by then.

## Readiness review

Refined 2026-11-19 by Claude Code (claude-opus-5-5).

- **Goal, restated:** for people and agents who rebuild or change the system: one place that says what it does now, separate from how each change was made. The smallest change: `docs/features/` as the living spec, edited in place; built ticket docs in `docs/tickets/`, frozen; links both ways.
- **Is it needed:** not built (`docs/`, `AGENTS.md`, `.agents/skills/` all move a built ticket's doc to `docs/features/`). Overlaps: PR #13 (now #17)'s three runner docs and ticket 0004 say their doc moves to `docs/features/`; this ticket updates those lines, or PR #13 (now #17) is updated if it merges later. The `new` and `ready` commands row names `docs/features/` too. Dropped before: no (`git log -p --follow -- docs/backlog/README.md`, commit messages).
- **Definition of Ready** (before review round 1): 1 pass (Summary: who, what changes, what doesn't); 2 pass (see "Is it needed"); 3 pass (Out of scope); 4 pass (docs and skills, one PR); 5 pass (every path, section, line format, and moved section named); 6 pass (one task for the user: start no ticket builds until this merges, Q9); 7 pass (seven checks, each with where and what shows it passed; check 7 after the merge, in the next ticket's doc); 8 pass (rule 3 changes, rule 4 kept); 9 pass (no code or secrets; the failure modes and the known gap); 10 pass (Q1 to Q9 answered)
- **Questions and answers:**
  - Folder name → `docs/tickets/` (the user's choice, over `docs/changelog/` and `docs/changes/`).
  - Q1: a built ticket's doc keeps its design as marked ready? → no: updated to as implemented, then frozen (the user's counter-proposal, accepted).
  - Q2: decisions only in ticket docs → yes.
  - Q3: only a new capability gets a spec doc, with its ticket's number → yes, "improved by never deleting a spec doc".
  - Q4: an index, `docs/tickets/README.md` → yes.
  - Q5: this PR converts 0003 and gives 0001 and 0002 Changes lists → yes.
  - Q6 (from the user's point that frozen tickets' links could break): spec docs never renamed or deleted, and no section links from ticket docs → yes.
  - Q7 (after review round 1): if 0004 or another ticket is built under the old layout first, this PR converts it, and its file in `docs/features/` stays as a stub saying it was merged into the spec doc it changed → yes (2026-11-19). Its fallback and stub replaced by Q8.
  - Q8 (after review round 5, the user's proposal): make everything old match the new layout before this merges, instead of a fallback in the skills → yes (2026-11-19). And so a converted ticket leaves no stub, since the never-delete rule starts with this PR → yes (2026-11-20).
  - Q9 (after review round 7, which found a race at cutover): drop the conversion of any ticket other than 0003, and its pause and per-case checks; if one turns up, the builder stops and asks; the user starts no ticket builds until this merges; and stop reviewing → yes (2026-11-20). Rounds 3 to 7 had gone mostly to that case, which doesn't exist.
- **Review round 1:** Codex (gpt-6.1-sol) and opencode (ollama-cloud/kimi-k3.1-pro), run separately. Both restatements match. 16 findings (Codex 7, opencode 9); 6 found by both, so 10 in all. All checked against the files and kept; none dropped.
  - Both (blocking): check 6 edited this ticket's doc after its merge, which "Frozen" forbids, and 0003's note says a later result "goes here". Fixed: later results go in the later ticket's doc, which links back; 0003's note gets its result before the move (this ticket's own refinement).
  - Both (blocking): 0003's history links `../backlog/0004-delete-expired-sessions.md#readiness-review`, which breaks when 0004 is built, and frozen docs can't be fixed. Fixed: the stable-link rule (spec docs by file, other ticket docs, permalinks for the rest), applied when a ticket doc moves (step 2).
  - Both (blocking): refine-ticket step 9.1's "Blocked by" check needs the item in the Features table, which this ticket and any ticket changing an existing capability never join. Fixed: built means listed in `docs/tickets/README.md` (or, for 0001 and 0002, the Features table); check 1 tests it.
  - Both (blocking): 0003's spec would still describe the old number sources and search (`0003-refine-ticket-skill.md:37`, `:84`). Fixed: the 0003 updates are listed, and check 4 tests them.
  - Both (blocking): 0004 is `ready` and could be built first, leaving a second accounts doc. Fixed as far as the doc goes: "Tickets built under the old layout"; the stub is Q7.
  - Both (blocking): rule 3 exempts docs-only PRs, the likeliest to rename a spec doc or edit a frozen one. Fixed: the new invariants hold for every PR; only the spec-update requirement keeps the exemption.
  - Codex (minor): the Changes line's `../tickets/` path is wrong from `docs/README.md` and `docs/devops.md`. Fixed: the path per location.
  - opencode (blocking): this ticket's Spec docs changed line left out 0001 and 0002, which it edits. Fixed: all four spec docs, each with a Changes line; check 4.
  - opencode (blocking): the no-section rule was only on one line of the build step, and 0004 links `0001-accounts.md#data-model` and `devops.md#environments`. Fixed: the stable-link rule in "Concepts", in `docs/README.md`, and in the build step, with 0004 as the example; check 3 covers every link in `docs/tickets/`.
  - opencode (minor): check 2 grepped only `docs/features/`, missing `docs/README.md:42`'s "into `features/`". Fixed: both spellings, with the remaining hits listed.
- **Review round 2:** Codex (gpt-6.1-sol) and opencode (ollama-cloud/kimi-k3.1-pro), asked for blocking findings only. Both restatements match. 10 findings (Codex 3, opencode 7); 3 found by both, so 7 in all. All checked and kept, all blocking; none dropped.
  - Both: permalinks "at the commit the branch started from" break when 0004 has moved first, and `git merge-base` moves once `main` is merged in (`next-ticket/SKILL.md:61`). Fixed: the newest commit on `main` with the file (or the parent of the one that moved it); files the PR adds are plain text.
  - Both: this ticket adds a Changes section to `docs/devops.md` but listed four spec docs, not five; and 0004 changes `devops.md` too (`0004-delete-expired-sessions.md:103`). Fixed: five, and 0004's line names both.
  - Both: check 2 required every remaining hit to be a link or number source, but the design needs "write `docs/features/NNNN-<slug>.md`" and step 3's search place, and its grep didn't exclude `docs/tickets/`. Fixed: the expected kinds of hit, and `--exclude-dir=tickets`.
  - opencode: 0003 changed `docs/README.md` (`0003-refine-ticket-skill.md:157`), but its Spec docs changed line named only its own doc. Fixed: both, and a 0003 line in `docs/README.md`'s Changes.
  - opencode: Q7's conversion fit only a ticket that changed existing capabilities. Fixed: three cases (existing, new, both).
  - opencode: an old-layout ticket PR still open when this merges had no owner for its conversion. Fixed: its builder converts it before it merges; this PR's body lists open ticket PRs.
  - opencode: check 3 didn't check a permalink's `#…`, or that its commit is on `main`. Fixed: both.
- **Review round 3:** Codex (gpt-6.1-sol) and opencode (ollama-cloud/kimi-k3.1-pro), blocking findings only. Both restatements match. 5 findings (Codex 1, opencode 4), none found by both. All checked and kept, all blocking; none dropped.
  - Codex: converting an old-layout ticket changes more spec docs than the five listed, and check 4 required exactly five. Fixed: the five are the minimum, and a conversion's docs are added.
  - opencode: the conversion was only in this ticket's doc, where a builder with an open old-layout PR wouldn't look. Fixed: it goes in the backlog's "How it works", and `next-ticket` step 2 checks where the doc is first.
  - opencode: the conversion didn't say what happens to the old Features row. Fixed: removed for a ticket that changed existing capabilities only, kept otherwise; check 5.
  - opencode: the permalink rule promised a commit with the heading but gave no way to find it, and no fallback for a heading the PR adds. Fixed: go through the file's history for the heading; drop the `#…` if no commit on `main` has it.
  - opencode: check 4's `git diff --color-moved` had no range, so on a committed branch it shows nothing. Fixed: `origin/main...HEAD` and the two paths.
- **Review round 4:** Codex (gpt-6.1-sol) and opencode (ollama-cloud/kimi-k3.1-pro), blocking findings only. Both restatements match. Codex: no findings, and round 3's fixes hold. opencode: 4 findings, all checked and kept, all blocking; none dropped.
  - opencode: a builder with an open old-layout PR is past step 2, and step 4's merge of `main` doesn't send it back (`next-ticket/SKILL.md:61`). Fixed: step 4 checks where the doc is after each merge, converts it, and fixes the PR body's path.
  - opencode: refine-ticket step 9.3 fixes links to a renamed doc everywhere in `docs`, frozen ticket docs included (`refine-ticket/SKILL.md:156`). Fixed: outside `docs/tickets/` only.
  - opencode: check 2's expected hits left out the conversion instructions. Fixed: listed.
  - opencode: check 5 relied on the builder's word. Fixed: commands and output, including that every acceptance check of the converted ticket is in a spec doc.
- **Review round 5:** Codex (gpt-6.1-sol) and opencode (ollama-cloud/kimi-k3.1-pro), blocking findings only. Both restatements match. Codex: no findings, and round 4's fixes hold. opencode: 3 findings, all checked and kept, all blocking, all in the conversion of an old-layout ticket; none dropped. After five rounds with blocking findings, the user was asked how to go on, and proposed Q8, which removes the conversion from the skills and the backlog: all three findings go with it.
  - opencode: step 4's "if the doc is in `docs/features/`, convert it" fires again after the conversion, since the stub or spec stays there. Needs: convert only while `docs/tickets/NNNN-<slug>.md` doesn't exist.
  - opencode: check 5 runs only when this PR converts a ticket, not when an open PR converts itself, and has no assertions for the "Both" case.
  - opencode: step 6's "fix links to the old path" is ambiguous for a conversion, whose old path stays as a stub or spec.
  - Resolved by Q8, as far as round 6 found: no builder converts its own ticket, so step 4 has no check to re-fire; check 5 now checks that nothing is left in the old layout, covering all three cases; and "Tickets built under the old layout" says where a converted ticket's links point.

- **Review round 6:** Codex (gpt-6.1-sol) and opencode (ollama-cloud/kimi-k3.1-pro), blocking findings only, after Q8. Both restatements match. 8 findings (Codex 3, opencode 5); 3 found by both, so 5 in all. All checked and kept, all blocking; none dropped.
  - Both: the open-PR query matches this ticket's own PR, so "prints nothing" can't pass. Fixed: it prints only this ticket's branch and PR.
  - Both: a ticket claimed and being built has a branch, and may have its doc in `docs/features/`, but no PR yet, so the query misses it. Fixed: the claim branches are listed too, and each other one is merged first or released by the user; holding it isn't an option.
  - Both: check 5's "every ticket on `main` with a number below this one's" includes 0004, still `ready`, and gave no way to list them. Fixed: the docs ever added to `docs/features/`, from git, each in the index other than 0001 and 0002.
  - opencode: check 5's grep for `^## Readiness review` matches 0003's spec heading "Readiness review section" (`0003-refine-ticket-skill.md:101`). Fixed: the whole heading.
  - opencode: check 5 had assertions for the "existing capabilities only" case, not "new capability" or "Both". Fixed: per case.

- **Review round 7:** Codex (gpt-6.1-sol) and opencode (ollama-cloud/kimi-k3.1-pro), blocking findings only. Both restatements match. 4 findings (Codex 1, opencode 3); 1 found by both, so 3 in all. 2 kept, 1 dropped.
  - Both: a ticket claimed, or a ticket PR merged, after the final check and before this PR merges, slips past it, with no conversion instructions left. Fixed: the cutover is a pause the user confirms, from the final check until the merge; the builder starts over if anything reaches `main` during it.
  - opencode: check 5's per-case checks look only at acceptance scenarios, so a conversion could drop other spec content (0004's migration locking, for example) and pass. Fixed: a destination map per spec section, with the moved-lines diff.
  - opencode, dropped: `--diff-filter=A` would miss a doc moved with `git mv`, seen as a rename. Run: limited to `docs/features`, `git log` shows 0003 as `A` (41516db), and the command lists 0001, 0002, and 0003. `--no-renames` added anyway, so it doesn't depend on rename detection.

- **Stopped after round 7** (Q9, the user, 2026-11-20). Round 7's two kept findings were in the conversion of a ticket other than 0003, which Q9 removed, so they no longer apply. No round 8: Codex found nothing outside that case in rounds 4 to 7.

## Decisions made for this ticket

- **The folder is `docs/tickets/`** (the user, 2026-11-19): it says what's in it. `docs/changelog/` would clash with release-please's `CHANGELOG.md` files and rule 4; `docs/changes/` was the other option.
- **Spec docs are never renamed or deleted** once the PR that adds them has merged (Q6, the user, 2026-11-19; the "once merged" made explicit 2026-11-20, at the user's request). Before then, nothing frozen links the doc: a design doc in `docs/backlog/` is renamed freely, as `agent-build` was to `agent-runner`, and so is a new spec doc inside its build PR. A removed capability's doc becomes a stub. Links from frozen ticket docs and from the release changelogs, which can't be edited, then keep working. The other option, letting ticket docs be edited for link fixes only, would weaken "history isn't edited" and wouldn't help the changelogs. Ticket docs link spec docs by file, never by section, since headings change.
- **A built ticket's doc is updated to what was built, then frozen** (Q1, the user, 2026-11-19). It's a snapshot of that part of the spec on the day it merged. The version marked ready stays in git, and "Delivery and review" says what changed from it.
- **Decisions live only in ticket docs** (Q2, the user, 2026-11-19). The spec doc stays lean, and its Changes list links the ticket docs, where the reasons are.
- **Only a new capability gets a spec doc,** with its ticket's number (Q3, the user, 2026-11-19). A spec doc per ticket would bring back several docs per capability. `docs/features/`'s numbers get gaps. Never deleting a spec doc means a number, once used there, stays used.
- **An index, `docs/tickets/README.md`** (Q4, the user, 2026-11-19): one row per built ticket, with its PR and the spec docs it changed.
- **This PR converts 0003, and gives 0001 and 0002 Changes lists** (Q5, the user, 2026-11-19), so every spec doc follows the layout from the start.
- **Only 0003 is converted; anything else built under the old layout stops for the user** (Q7, Q8, and Q9, the user, 2026-11-19 and 2026-11-20). Q7 had this PR convert any such ticket, with a stub; Q8 kept the conversion in this PR, not in the skills; Q9 dropped it, with its pause and per-case checks. Rounds 3 to 7 went mostly to that case, which doesn't exist: the user starts the agents, and builds this ticket next. Writing it out would have cost more than handling it once, if ever.
