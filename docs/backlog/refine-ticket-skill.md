# A skill that gets a ticket ready to build

Status: **designed**. When the user marks it `ready`, it gets a number and this doc is renamed `NNN-refine-ticket-skill.md`. It moves to `docs/features/` in the PR that builds it.

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

1. **Reads** the backlog row, the design doc, `AGENTS.md`, `docs/README.md`, the feature docs and code the item touches, and `docs/devops.md` if it's operational. For an `idea` with no doc, it writes a first draft of the doc with the feature doc sections (see [../README.md](../README.md#writing-a-feature-doc)), then continues.
2. **Restates the goal in its own words.** In a few sentences: who it's for, what problem it solves, and the smallest change that would solve it. This opens the report, so the user can see at once whether the skill understood the item.
3. **Checks that the work is needed:**
   - **Already built?** It searches the code and the feature docs by concept, not just by the item's wording, and reports where it looked.
   - **Overlaps or conflicts?** It looks for another backlog item, or an open PR, that covers the same ground or contradicts it.
   - **Dropped before?** It looks in the backlog's git history for a dropped item like this one. Dropping an item records why, in the commit message.

   If any of these turns up something, the skill reports it and asks the user whether to go on.
4. **Checks the doc against the Definition of Ready** (below). It notes each item as pass, fail, or not applicable, with a reason.
5. **Settles what's open.** It finds the facts itself: it reads the code, or runs a quick probe or prototype when only running something can tell. It then interviews the user about the remaining decisions with the `grilling` skill, in rounds, and waits for the answers. It writes each answer into the doc: in the section it belongs to, and in "Decisions made for this ticket" if it was a choice. It never guesses at anything that changes the scope or the behavior.
6. **Proposes a split** if the item fails the size check. The parts are **vertical slices**, in the style of Matt Pocock's `to-tickets`:
   - Each part delivers a narrow behavior end to end, through every layer it needs (data, API, app, tests). It can be shipped and checked on its own, not as one layer of the whole.
   - Each part fits in one agent session.
   - Any restructuring of existing code that makes the work easier comes first, as its own part.
   - A wide mechanical change, such as a rename across the codebase, goes in stages instead: add the new form beside the old, move the callers over in batches, then remove the old form.
   - Each part names the parts that block it.

   The skill shows the proposed parts as a numbered list, each with a title, what it delivers, and what blocks it. It asks the user whether the size is right and the blocking is correct, and changes it until the user agrees. Then each part becomes its own backlog item, with "Blocked by: …" at the start of its Notes, and the skill refines each one separately.
7. **Gets an independent review.** Each reviewer is a fresh agent that gets the doc and the repo, with none of this conversation's context.
   - **Round 1 has two reviewers,** run separately so neither sees the other's report. Where they're available, they're the two agents that didn't refine the doc: for a doc refined by Claude Code, Codex and opencode. With only one other agent, the second reviewer is a fresh session of the refining agent's own model. Two reviewers find more than one, and the round shows which one is more useful for this ticket, rather than the skill picking one up front.
   - **Later rounds have one reviewer:** a fresh session of the round-1 reviewer whose findings were the most useful, meaning the most findings kept (fixed in the doc, or turned into a question for the user) rather than answered or dropped. It also gets the previous rounds' findings and what was done about each, so it can check the fixes as well as look for new gaps. If the two were about even, the skill asks the user which to keep.

   Each reviewer:
   - first restates the goal in its own words. If its restatement differs from the skill's in step 2, that difference is a finding: the doc can be read two ways.
   - checks the doc against the Definition of Ready, and tries to break it: missing cases, wrong assumptions about the code, checks that can't fail.
   - backs each finding with evidence, such as the file and line it relies on, or a command and its output. A finding without evidence is dropped, and the report says how many were dropped and why.
   - only reads, and doesn't edit. The refining agent makes the changes.

   Each finding is fixed in the doc, or answered with the reason it stays, just like a PR finding. Fixes that need a decision go back to the user through step 5. After the fixes, the next round runs. After three rounds with findings still coming, the skill stops and asks the user.
8. **Asks the user for approval.** When the doc passes the checklist and the review has nothing left, the skill shows the user:
   - the goal, restated
   - the checklist results
   - what changed in the doc, and the questions and answers
   - the review findings, and what was done about each

   Then it asks: "Mark it ready?"
9. **Marks it ready, only if the user says yes**, on a branch and in a PR. That PR gives the ticket the next free number, renames the doc to `NNN-<slug>.md`, and sets the row's number, link, and status. The user merges the PR, so the ticket becomes `ready` on `main` only through the user.

   **Reserving the number.** A number is only unique on `main`, so two refinements in parallel could both pick the same one for their PRs. The number is reserved the same way a ticket is claimed: by creating a branch named after it on `origin`, here `ready-NNN`, which is also the PR's branch.
   1. Take one more than the highest number used in `main`'s backlog table, in `docs/features/`, and in the names of all `NNN-*` and `ready-NNN` branches on `origin`.
   2. Push the branch create-only (`--force-with-lease=refs/heads/ready-NNN:`), and check that `origin` has this commit, as `scripts/ticket.sh claim` does.
   3. If another refinement got there first, take the next number and try again.

   Until `scripts/ticket.sh ready` exists (see the backlog), the skill follows these steps by hand. Once it exists, the command does them. If the user says no, or asks for changes, the skill keeps the doc `designed`, makes the changes, and goes back to step 4.

At any step, the user can stop. The doc keeps whatever was settled so far, and the status stays `designed`.

## The Definition of Ready

Added as a section of `docs/backlog/README.md`. A ticket is ready when:

1. **Purpose:** the summary says what problem it solves, for whom, and what changes for users or operators. It also says what doesn't change. For a change to existing behavior, it states the current behavior and the behavior wanted.
2. **Needed:** it isn't already built, and it doesn't repeat or contradict another backlog item or something dropped before.
3. **Scope:** what's in and what's out is explicit, including an out-of-scope list for anything nearby that a builder might be tempted to include. Anything left for later is a separate backlog row or a known gap, not a vague "maybe".
4. **Fits one PR:** one branch, one reviewable PR, one behavior change that can ship on its own, and small enough for one agent session. A rough guide: if the implementation map touches more than about three areas (app, server, CI, infra), or the acceptance checks fall into groups that could each ship alone, split it.
5. **Enough information to build it without asking:**
   - every endpoint, table, setting, message, and error code it adds or changes, with exact values
   - the files in the implementation map exist, or are clearly new files
   - links to the feature docs it changes
   - the backlog items that block it, if any
6. **Steps only the user can do** are listed as tasks for the user: settings, secrets, rulesets, accounts, and anything else an agent can't do. For each one, the doc says when it has to happen (before the PR is merged, or after it ships) and how the builder can check that it's done.
7. **Acceptance checks:** each one is a concrete scenario, with an input or setup and an observable expected result. They cover the failure paths and edge cases, not just the happy path. No check uses words like "works", "fast", or "secure" without saying what's measured. Each check also says:
   - **where it's tested:** the highest existing entry point that can test it, such as the HTTP API through Fastify's `inject`, the claim script run against a scratch repo, a CI job, or the app on a device
   - **what shows it passed:** something other than the builder's word, such as a test, a CI job's result, or a command and its output
8. **The project's rules** (`AGENTS.md`) are addressed where they apply. For example:
   - attempt limits (rule 1)
   - more than one instance (rule 2): shared state, and migrations or jobs run by several instances at once
   - docs updated in the same PR (rule 3)
   - versions left to release-please (rule 4)
   - workflow permissions and triggers (rule 5)
9. **Security and failure modes:** who can trigger it, what happens when a dependency is down, and what's logged. It also lists the known gaps.
10. **No open questions.** Choices are written down in "Decisions made for this ticket", with the reason for each.

## Readiness review section

The skill records its work in a new section of the design doc, **Readiness review**, like "Delivery and review" records the build:
- the date, the goal as restated, and the results of the checks that the work is needed
- the checklist results
- the questions asked, and the user's answers
- each review round: who reviewed (agent and model), and after round 1, which reviewer was kept for later rounds and why; each reviewer's restatement of the goal, each finding with its evidence, what was done about it, and how many findings were dropped for lack of evidence
- the user's approval

That way, a ticket's history shows why it was considered ready. Item 9 of "Writing a feature doc" in `docs/README.md` describes the section.

## Security and configuration

- The skill only edits docs: the design doc, the backlog, and `docs/README.md`. It doesn't change code or settings.
- **Probes and prototypes** that find facts run in a scratch directory outside the checkout, or in a throwaway clone whose `origin` is a local bare repo. They're thrown away afterwards, and never committed. They may read the repo and run its tests and scripts there. They must not:
  - push, or change anything on GitHub (branches, PRs, issues, settings)
  - touch the user's development database, `server/.env`, or running servers
  - contact outside services, or use secrets

  A probe that would need any of these is a question for the user instead.
- Only the user's approval leads to `ready`, and only the user's merge puts it on `main`. The backlog's "Who sets it" column changes from "The user, in a PR to `main`" to "The user decides. An agent may make the edit after the user approves, in a PR the user merges." `AGENTS.md`'s "Only the user marks tickets `ready`" changes the same way.
- The independent reviewers get read-only access: it reports findings, and the refining agent makes the edits.

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

- `.agents/skills/refine-ticket/SKILL.md`: the skill. It follows the Skills section of `AGENTS.md`: Claude Code finds it through the `.claude/skills` symlink, and Codex and opencode read it directly. It calls the `grilling` skill for step 5.
- `.agents/skills/grilling/`: already added, in the PR that added this backlog item. Nothing to build.
- `docs/backlog/README.md`:
  - a "Definition of Ready" section
  - a link to the skill next to the `next-ticket` link
  - the updated "Who sets it" text
  - a "Refining it" step in "How it works", between designing an item and marking it ready
  - the "Blocked by: …" convention for the Notes column
  - in "Marking it ready", the `ready-NNN` branch that reserves the number
- `docs/README.md`: item 9 of "Writing a feature doc", **Readiness review**.
- `AGENTS.md`: the `refine-ticket` skill in "Backlog tickets", the updated rule about who marks tickets `ready`, and the Definition of Ready as context for reviewers.

## Acceptance checks

Each check is run by hand, with the transcript or the PR as the evidence, because the skill's behavior is an agent conversation and not code.

1. `claude`, `codex`, and `opencode`, each run in the repo, list the `refine-ticket` and `grilling` skills.
2. Run on the existing `designed` item "Delete expired session rows", the skill:
   - opens with the goal restated, and the results of the three "is it needed" checks, including where it looked
   - produces checklist results for all 10 items
   - asks only about decisions, never about facts it could have looked up, in numbered rounds with a recommended answer for each, and writes the answers into the doc
   - runs round 1 of the review with two fresh reviewers that don't see each other's reports, and any later round with only the reviewer whose findings were the most useful
   - records each round in a "Readiness review" section: who reviewed, each reviewer's restatement, each finding with its evidence, what was done about it, and which reviewer was kept and why
   - then asks the user to approve
3. If the user says no, the item stays `designed`, and the doc and the row on `main` don't change status.
4. If the user says yes, the skill opens a PR that gives the item the next free number, renames the doc, and sets the row to `ready`. After the user merges it, `scripts/ticket.sh list` shows the ticket as `ready`.
5. Run on an `idea` row with no design doc, the skill first writes a draft doc with the feature doc sections, then refines it.
6. Run on an item that is too big, for example a made-up "OpenTelemetry for the server and the app" with no design, the skill proposes vertical slices, each with what it delivers and what blocks it. With the user's agreement, it adds them to the backlog, each with "Blocked by: …" in its Notes.
7. Two refinements approved at the same time get different numbers: the second one's create-only push of `ready-NNN` fails, and it takes the next number. Tested with two clones and a local bare `origin`, as the claim script was.
8. Run on a made-up item for something that already exists, for example "Let users log out", the skill reports that it's already built, with where (feature 001), and asks before going on.
9. Probes run only in a scratch directory or a throwaway clone. After a refinement, `git status` in the checkout shows only the doc changes, and `origin` has no new branches other than `ready-NNN`.
10. The skill never sets a status to `ready` without the user's yes in the same conversation, and never merges a PR.
11. The Definition of Ready section exists in `docs/backlog/README.md`. `AGENTS.md`, the backlog README, and `docs/README.md` describe the skill and the Readiness review section, and their wording about who marks tickets `ready` matches.

## Decisions made for this ticket

Change these before marking it ready if you disagree:
- **The Definition of Ready lives in the backlog README, not in the skill,** so people and other reviewers see the same list, and changing it doesn't mean changing a skill.
- **The skill can make the `ready` edit, but only after the user's explicit yes, and only in a PR the user merges.** This keeps the user's decision and lets the agent do the bookkeeping. The rule's wording changes to say so.
- **The interview uses the separate `grilling` skill,** copied from Matt Pocock's skills (decided 2026-11-17), because it's useful beyond refining tickets.
- **Review findings need evidence,** and those without it are dropped. Review rounds then converge on real gaps instead of growing with speculation.
- **At most three independent review rounds** before the user is asked. It keeps the loop from running forever on a ticket that's not converging.
- **Two reviewers in round 1, then the more useful one** (suggested by the user, 2026-11-17). With Claude Code, Codex, and opencode set up, the two agents that didn't refine the doc can both review it, so there's no need to guess which one will do better. Later rounds mostly check the fixes, and one reviewer is enough for that.
- **A different model for the independent review where possible.** It's not required: a fresh agent of the same model with no shared context is still independent.
- **File paths stay in the implementation map,** unlike Matt Pocock's briefs. See "Prior art".
