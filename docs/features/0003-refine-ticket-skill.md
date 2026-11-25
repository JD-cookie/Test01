# A skill that gets a ticket ready to build

Status: implemented. The skill is [`.agents/skills/refine-ticket/SKILL.md`](../../.agents/skills/refine-ticket/SKILL.md), and its reviewer prompt is [`review-prompt.md`](../../.agents/skills/refine-ticket/review-prompt.md) beside it.

## Summary

Before an agent builds a ticket, someone has to be sure the ticket says what to build. Today that's only the user's own reading of the design doc. This feature adds an agent skill, `refine-ticket`. It takes a backlog item (`idea` or `designed`) and works on it until it's ready to build:
- It checks the design doc against a written **Definition of Ready**.
- It interviews the user about the decisions that are still open, using the `grilling` skill, and writes the answers into the doc.
- It proposes splitting the item if it's too big for one PR.
- It gets an independent, adversarial review of the doc.

When the item passes, the skill asks the user to approve it. Only with that approval does it mark the ticket `ready`, in a PR the user merges.

The point is to move review earlier. In PR #7, several of Qodo's findings were design gaps in the tickets, not bugs in the code:
- the migration race in the expired-sessions ticket
- `app-v*` releases publishing server images
- the publish workflow being startable by hand

Each would have been cheaper to catch before the ticket was ready to build.

## Concepts

- **Definition of Ready (DoR):** the checklist a ticket has to pass before it's `ready`. It lives in `docs/backlog/README.md`, so that people, the skill, and reviewers such as Qodo all use the same list. The skill applies it, but doesn't own it.
- **Refinement:** improving a ticket's design doc until it meets the Definition of Ready. The term comes from Scrum ("backlog refinement").
- **Grilling:** an interview in rounds, from the `grilling` skill (`.agents/skills/grilling/`, copied from Matt Pocock's skills). The open decisions form a tree. Each round asks every question whose prerequisites are already settled. Each question is numbered and comes with a recommended answer, worded so that "yes" accepts it. Questions that depend on an answer not given yet wait for a later round.
- **Facts versus decisions:** a fact can be found by reading the repo, the docs, or the code, or by running something. Finding facts is the agent's job. A decision is a product or preference choice, and only the user makes it. The skill never asks the user for a fact.
- **Independent review:** a review by an agent that didn't write the doc and hasn't seen the conversation that shaped it. It gets only the repo and the doc, the way the building agent will. Here it's also **adversarial**: the reviewer tries to show the doc is wrong or incomplete, and each finding has to come with evidence.

## User-facing behavior

The user asks an agent to refine an item, for example "refine the delete-expired-sessions ticket". The skill then:

1. **Reads** the backlog row, the design doc, `AGENTS.md`, `docs/README.md`, the feature docs and code the item touches, and `docs/devops.md` if it's operational. For an `idea` with no doc, it writes a first draft of the doc with a ticket doc's sections (see [../README.md](../README.md#writing-a-feature-doc)) once step 3 shows the work is needed, and sets the row to `designed`. It works on a local branch, `refine-<slug>`, from an up-to-date `main`, and asks first if the checkout has changes. It doesn't push that branch.
2. **Restates the goal in its own words.** In a few sentences: who it's for, what problem it solves, and the smallest change that would solve it. This opens the report, so the user can see at once whether the skill understood the item.
3. **Checks that the work is needed:**
   - **Already built?** It searches the code, the spec docs in `docs/features/`, and the built tickets in `docs/tickets/` by concept, not just by the item's wording, and reports where it looked.
   - **Overlaps or conflicts?** It looks for another backlog item, or an open PR, that covers the same ground or contradicts it.
   - **Dropped before?** It looks in the backlog's git history for a dropped item like this one. Dropping an item records why, in the commit message.

   If any of these turns up something, the skill reports it and asks the user whether to go on.
4. **Checks the doc against the Definition of Ready** (below). It notes each item as pass, fail, or not applicable, with a reason.
5. **Proposes a split** if the item fails the size check, before settling the other decisions, because those are asked for each part once it's its own item. If the size depends on a decision, it asks that one first. The parts are **vertical slices**, in the style of Matt Pocock's `to-tickets`:
   - Each part delivers a narrow behavior end to end, through every layer it needs (data, API, app, tests). It can be shipped and checked on its own, not as one layer of the whole.
   - Each part fits in one agent session.
   - Any restructuring of existing code that makes the work easier comes first, as its own part.
   - A wide mechanical change, such as a rename across the codebase, goes in stages instead: add the new form beside the old, move the callers over in batches, then remove the old form.
   - Each part names the parts that block it.

   The skill shows the proposed parts as a numbered list, each with a title, what it delivers, and what blocks it. It asks the user whether the size is right and the blocking is correct, and changes it until the user agrees. Then each part becomes its own backlog item, with "Blocked by: …" at the start of its Notes, and the skill refines each one separately.
6. **Settles what's open.** It finds the facts itself: it reads the code, or runs a quick probe or prototype when only running something can tell. It then interviews the user about the remaining decisions with the `grilling` skill, in rounds, and waits for the answers. It writes each answer into the doc: in the section it belongs to, and in "Decisions made for this ticket" if it was a choice. It never guesses at anything that changes the scope or the behavior.
7. **Gets an independent review.** Each reviewer is a fresh agent that gets the doc and the repo, with none of this conversation's context.
   - **Every round has two reviewers,** run separately so neither sees the other's report, as fresh sessions each round. Where they're available, they're the two agents that didn't refine the doc: for a doc refined by Claude Code, Codex and opencode. With only one other agent, the second reviewer is a fresh session of the refining agent's own model. Two reviewers find different problems, in later rounds as well as the first.
   - **Later rounds** also get the previous rounds' findings and what was done about each, so the reviewers check the fixes as well as look for new gaps. They report only **blocking** findings: ones that would make a build that follows the doc come out wrong, or that a builder would have to ask about or guess. Other findings, such as wording, are **minor**. Every finding says which it is, and the refining agent decides when it checks the finding.

   Each reviewer:
   - first restates the goal in its own words. If its restatement differs from the skill's in step 2, that difference is a finding: the doc can be read two ways.
   - checks the doc against the Definition of Ready, and tries to break it: missing cases, wrong assumptions about the code, checks that can't fail.
   - backs each finding with evidence, such as the file and line it relies on, or a command and its output. A finding without evidence is dropped, and the report says how many were dropped and why.
   - only reads, and doesn't edit. The refining agent makes the changes.

   Each reviewer gets the same prompt, `review-prompt.md` in the skill's folder, and runs as a separate CLI process in a **review copy**: a throwaway clone of the refinement branch, in a scratch directory, with its remote removed. It has only committed files, so none of the ignored ones such as `server/.env` or the development database, and nothing to push to. Each CLI also runs in a read-only mode:
   - **Codex:** `codex exec -s read-only -c approval_policy='"never"' --ephemeral`. The `approval_policy` override is needed: with a user config of `approval_policy = "on-request"` and `approvals_reviewer = "auto_review"`, Codex asked to leave the read-only sandbox, its automatic approver said yes, and it wrote files. With `never`, the sandbox held.
   - **opencode:** `opencode run --standalone --agent plan -m <model>`, with the model chosen by rotation (below), with `opencode-reviewer.json` from the skill's folder copied into the clone as `opencode.json`. The built-in `plan` agent only denies edits: it allows every shell command, subagents, and the web. The project config overrides user settings: it denies everything, then allows only the `read`, `grep`, `glob`, and `list` tools. `opencode debug agents --standalone` shows the merged rules. `--standalone` matters: opencode's background service caches each directory's config the first time it sees it, so a changed config isn't read again.
   - **Claude Code:** `claude -p --permission-mode plan --tools Read,Grep,Glob --strict-mcp-config`: only those three tools exist in the session.

   **opencode's model rotates.** `reviewers.md` in the skill's folder lists candidate models (`ollama-cloud/glm-5.3`, `ollama-cloud/kimi-k3.1-pro`, `ollama-cloud/deepseek-v4-pro` to start). Each refinement uses the candidate with the fewest rows in its results table, the one higher in the list on a tie. After each round, the refining agent adds a row per reviewer: date, item, round, agent, model, and the kept, answered, and dropped counts. A model added to the list starts with no rows, so it's tried next. Codex and Claude use their configured defaults; if one is a small model, the skill asks the user.

   Only Codex has a shell, in a sandbox the OS enforces. A shell with some commands allowed isn't read-only (`git diff --output=<file>` writes a file), so reviewers don't run anything. A claim that only a run can check comes back as a **needs a run** finding, with the command, and the refining agent runs it as a probe: it's kept if the output shows the problem.

   After each round, the skill checks that `git status --porcelain --ignored` in the clone and in the checkout, and the branches on `origin`, are as before. If anything changed, it stops and tells the user. Those checks only confirm the read-only modes: they can't see changes outside the repo.

   Each finding is fixed in the doc, or answered with the reason it stays, just like a PR finding. Fixes that need a decision go back to the user through step 6. After the fixes, the next round runs. The review stops after a round with no kept blocking findings; its minor ones are fixed without another round. After five rounds with kept blocking findings still coming, the skill stops and asks the user.
8. **Asks the user for approval.** When the doc passes the checklist and the last review round had no kept blocking findings, the skill shows the user the following. If the row's "Blocked by: …" names an item that isn't built yet, it also tells the user that the ticket will be marked `ready` but will wait until those items are built, naming them: `scripts/ticket.sh` won't let it be claimed before then (see [0008-ticket-system.md](0008-ticket-system.md)). That isn't a reason to stop.
   - the goal, restated
   - the checklist results
   - what changed in the doc, and the questions and answers
   - the review findings, and what was done about each

   Then it asks: "Mark it ready?"
9. **Marks it ready, only if the user says yes**, on a branch and in a PR. That PR gives the ticket the next free number, renames the doc to `NNNN-<slug>.md`, and sets the row's number, link, and status. The user merges the PR, so the ticket becomes `ready` on `main` only through the user.

   **Reserving the number.** A number is only unique on `main`, so two refinements in parallel could both pick the same one for their PRs. The number is reserved the same way a ticket is claimed: by creating a branch named after it on `origin`, here `ready-NNNN`, which is also the PR's branch.
   1. Take one more than the highest number used, as four digits, zero-padded, in `main`'s backlog table, in `docs/features/` and `docs/tickets/`, and in the names of all `NNNN-*` and `ready-NNNN` branches on `origin`. `docs/features/` has gaps, since a ticket that changes an existing capability adds no file there, so `docs/tickets/` counts too.
   2. Push the branch create-only (`--force-with-lease=refs/heads/ready-NNNN:`), and check that `origin` has this commit, as `scripts/ticket.sh claim` does.
   3. If another refinement got there first, take the next number and try again.
   4. Before step 1, check on a fresh `main` that the item still has no number, and check each item named in its "Blocked by: …" notes, or a "Blocked by" in any other spelling. One whose row is still in the backlog prints `not built: <title>`: that isn't a stop, and the ready PR's description names the items the ticket waits on. One with no row that isn't listed as built either, in `docs/tickets/README.md`, or, for features built before the backlog (0001 and 0002), in the Features table of `docs/README.md`, prints `unknown: <title> (not in the backlog or built)`, and stops the skill: it's a typo or a dropped item, which the user fixes in the row first. So does an empty entry in the list (`Blocked by: .`), and a Notes cell that starts "Blocked by" spelled any other way (`Blocked By: A`, `Blocked by:A`), both of which `scripts/ticket.sh` counts as an unknown blocker.
   5. After the push, check that `$n` isn't on `main` now: in the backlog table, `docs/features/`, or `docs/tickets/`. A ready PR's branch is deleted when it merges, so another PR for the same number could have merged after step 1, and then the push still succeeds. If it's taken, the skill deletes its own reservation and starts over. After the reservation exists, `$n` can only reach `main` through this PR.
   6. Then check that no other `ready-*` branch changes the same item's **row**, diffed from where that branch left `main`. The row is the item's stable mark: a refinement may create the item's doc or rename it, but every ready PR changes the row's number and status. If one does, two agents refined the same item: the skill doesn't open the PR, and asks the user which to keep. Each agent checks after its own push, so two racing on one item can't both miss each other. Last, it checks the item's row on a fresh `main` once more: a ready PR for the same item that merged after step 1 has had its branch deleted, so only its row shows it. If the row has a number now, or is gone, the skill stops and tells the user.

   Any command that fails stops the skill: a check that couldn't run hasn't passed.

   The refinement's doc changes are one commit, and the ready edit is a second commit on top, so a lost race undoes only the second. The skill's step 9 has the exact commands. Until `scripts/ticket.sh ready` exists (see the backlog), the skill follows these steps by hand. Once it exists, the command does them. If the user says no, or asks for changes, the skill keeps the doc `designed`, makes the changes, and goes back to step 4. If the user wants to stop there, the skill asks whether to open a PR with the doc changes, status still `designed`, on `refine-<slug>`, and pushes it only on a yes.

At any step, the user can stop. The doc keeps whatever was settled so far, and the status stays `designed`.

## The Definition of Ready

The list is in [`docs/backlog/README.md`](../backlog/README.md#definition-of-ready), its only copy, so that people, the skill, and reviewers all use the same one. It has 10 items: purpose, needed, scope, fits one PR, enough information to build it without asking, steps only the user can do, acceptance checks (each with where it's tested and what shows it passed), the project's rules, security and failure modes, and no open questions. The skill marks each one pass, fail, or not applicable, with a reason.

## Readiness review section

The skill records its work in a new section of the design doc, **Readiness review**, like "Delivery and review" records the build:
- the date, the goal as restated, and the results of the checks that the work is needed
- the checklist results
- the questions asked, and the user's answers
- each review round: who reviewed (agent and model); each reviewer's restatement of the goal, each finding with whether it's blocking or minor, its evidence, what was done about it, and how many findings were dropped for lack of evidence
- the user's approval

That way, a ticket's history shows why it was considered ready. When the ticket is built, the section goes with its doc to `docs/tickets/`, and stays out of the spec doc. "Writing a feature doc" in `docs/README.md` describes it, among a ticket doc's sections.

## Security and configuration

- The skill only edits docs: the design doc, the backlog, and `docs/README.md`. It doesn't change code or settings.
- **Probes and prototypes** that find facts run in a scratch directory outside the checkout, or in a throwaway clone whose `origin` is a local bare repo. They're thrown away afterwards, and never committed. They may read the repo and run its tests and scripts there. They must not:
  - push, or change anything on GitHub (branches, PRs, issues, settings)
  - touch the user's development database, `server/.env`, or running servers
  - contact outside services, or use secrets

  A probe that would need any of these is a question for the user instead.
- Only the user's approval leads to `ready`, and only the user's merge puts it on `main`. The backlog's "Who sets it" column changes from "The user, in a PR to `main`" to "The user decides. An agent may make the edit after the user approves, in a PR the user merges." `AGENTS.md`'s "Only the user marks tickets `ready`" changes the same way.
- The independent reviewers run read-only, in a review copy with no remote and no ignored files (see step 7 for how each CLI is held to it): they report findings, and the refining agent makes the edits.
- **Known gap:** a reviewer runs as the user, so it can still *read* files outside the review copy, such as the home directory. The read-only modes stop writes, not reads.

## Prior art

The design borrows from these MIT-licensed skill collections. The ideas are adapted, and only `grilling` is copied:
- **Matt Pocock's skills** ([mattpocock/skills](https://github.com/mattpocock/skills)):
  - `grilling`: the interview in rounds, and facts versus decisions. Copied into `.agents/skills/grilling/` with its license, because it's useful on its own too.
  - `triage`: the "already built?" and "rejected before?" checks before refining, and its agent brief guide's current versus wanted behavior and out-of-scope lists.
  - `to-tickets`: vertical slices, each fitting one agent session, with blocking edges, restructuring first, and staged wide changes.
  - `to-spec`: deciding up front where each behavior is tested, at the highest existing entry point.
  - `software-factory` (in progress): limit every automated loop to a few tries before a human steps in.
- **pstack** ([backnotprop/pstack](https://github.com/backnotprop/pstack)):
  - `interrogate`: adversarial review in which only findings backed by evidence survive.
  - `arena`: a judge from a different model vendor.
  - `in-your-own-words`: restating the goal first.
  - `sharpen`: asking what, other than the agent or the user, would show the result is right.
  - `principle-never-block-on-the-human`: settle facts by trying things, and keep questions for product and preference choices.

One idea is deliberately not taken: Matt Pocock's specs and briefs leave out file paths, because paths go stale. This project's docs have an implementation map on purpose, so the system can be rebuilt from the docs. The Definition of Ready only checks that the paths exist at the time of refinement.

## Implementation map

- `.agents/skills/refine-ticket/SKILL.md`: the skill, steps 0 to 9, the Readiness review template, and the limits on probes. It follows the Skills section of `AGENTS.md`: Claude Code finds it through the `.claude/skills` symlink, and Codex and opencode read it directly. It uses the `grilling` skill for step 6.
- `.agents/skills/refine-ticket/review-prompt.md`: the prompt each independent reviewer gets, with placeholders for the doc's path and the earlier rounds.
- `.agents/skills/refine-ticket/reviewers.md`: opencode's candidate models, in rotation order, and the results table each refinement adds to.
- `.agents/skills/refine-ticket/opencode-reviewer.json`: the opencode project config copied into each review copy, which limits the `plan` agent to reading.
- `.agents/skills/grilling/`: added in PR #8, with the backlog item.
- `docs/backlog/README.md`:
  - a "Definition of Ready" section
  - a link to the skill next to the `next-ticket` link
  - the updated "Who sets it" text
  - a "Refining it" step in "How it works", between designing an item and marking it ready
  - the "Blocked by: …" convention for the Notes column
  - in "Marking it ready", the `ready-NNNN` branch that reserves the number
- `docs/README.md`: **Readiness review**, in "Writing a feature doc", among a ticket doc's sections.
- `AGENTS.md`: the `refine-ticket` skill in "Backlog tickets", the updated rule about who marks tickets `ready`, and the Definition of Ready as context for reviewers.
- `.agents/skills/next-ticket/SKILL.md`: "don't mark anything `ready` yourself" now points to `refine-ticket`.

## Acceptance checks

Each check is run by hand, with the transcript or the PR as the evidence, because the skill's behavior is an agent conversation and not code.

1. `claude`, `codex`, and `opencode`, each run in the repo, list the `refine-ticket` and `grilling` skills.
2. Run on the existing `designed` item "Delete expired session rows", the skill:
   - opens with the goal restated, and the results of the three "is it needed" checks, including where it looked
   - produces checklist results for all 10 items
   - asks only about decisions, never about facts it could have looked up, in numbered rounds with a recommended answer for each, and writes the answers into the doc
   - runs every review round with two fresh reviewers that don't see each other's reports, and stops after the first round with no kept blocking findings
   - records each round in a "Readiness review" section: who reviewed, each reviewer's restatement, each finding with whether it's blocking or minor, its evidence, and what was done about it
   - then asks the user to approve
3. If the user says no, the item stays `designed`, and the doc and the row on `main` don't change status.
4. If the user says yes, the skill opens a PR that gives the item the next free number, renames the doc, and sets the row to `ready`. After the user merges it, `scripts/ticket.sh list` shows the ticket as `ready`, or as `waiting on: …` if an item in its "Blocked by" isn't built yet.
5. Run on an `idea` row with no design doc, the skill first writes a draft doc with the feature doc sections, then refines it.
6. Run on an item that is too big, for example a made-up "OpenTelemetry for the server and the app" with no design, the skill proposes vertical slices, each with what it delivers and what blocks it. With the user's agreement, it adds them to the backlog, each with "Blocked by: …" in its Notes.
7. Two refinements approved at the same time get different numbers: the second one's create-only push of `ready-NNNN` fails, and it takes the next number. Tested with two clones and a local bare `origin`, as the claim script was.
8. Run on a made-up item for something that already exists, for example "Let users log out", the skill reports that it's already built, with where (feature 0001), and asks before going on.
9. Probes run only in a scratch directory or a throwaway clone. After a refinement, `git status` in the checkout shows only the doc changes, and `origin` has no new branches other than `ready-NNNN`.
10. The skill never sets a status to `ready` without the user's yes in the same conversation, and never merges a PR.
11. The Definition of Ready section exists in `docs/backlog/README.md`. `AGENTS.md`, the backlog README, and `docs/README.md` describe the skill and the Readiness review section, and their wording about who marks tickets `ready` matches.

## Changes

- 0003: A skill that gets a ticket ready to build ([ticket](../tickets/0003-refine-ticket-skill.md))
- 0006: Keep the spec separate from the ticket history ([ticket](../tickets/0006-spec-and-tickets.md))
- 0008: Mark a blocked ticket `ready` before its blockers are built ([ticket](../tickets/0008-ready-before-blockers.md))
