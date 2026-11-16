# A skill that gets a ticket ready to build

Status: **designed**. When the user marks it `ready`, it gets a number and this doc is renamed `NNN-refine-ticket-skill.md`. It moves to `docs/features/` in the PR that builds it.

## Summary

Before an agent builds a ticket, someone has to be sure the ticket says what to build. Today that's only the user's own reading of the design doc. This feature adds an agent skill, `refine-ticket`, that takes a backlog item (`idea` or `designed`) and works on it until it's ready to build:
- It checks the design doc against a written **Definition of Ready**.
- It asks the user about anything unclear and writes the answers into the doc.
- It gets an independent review of the doc.
- It proposes splitting the item if it's too big for one PR.

When the item passes, the skill asks the user to approve it. Only with that approval does it mark the ticket `ready`, in a PR the user merges.

The point is to move review earlier. In PR #7, several of Qodo's findings were design gaps in the tickets, not bugs in the code:
- the migration race in the expired-sessions ticket
- `app-v*` releases publishing server images
- the publish workflow being startable by hand

Each would have been cheaper to catch before the ticket was ready to build.

## Concepts

- **Definition of Ready (DoR):** the checklist a ticket has to pass before it's `ready`. It lives in `docs/backlog/README.md`, so that people, the skill, and reviewers such as Qodo all use the same list. The skill applies it, but doesn't own it.
- **Refinement:** improving a ticket's design doc until it meets the Definition of Ready. The term comes from Scrum ("backlog refinement").
- **Independent review:** a review by an agent that didn't write the doc and hasn't seen the conversation that shaped it. It gets only the repo and the doc, the way the building agent will.

## User-facing behavior

The user asks an agent to refine an item, for example "refine the delete-expired-sessions ticket". The skill then:

1. **Reads** the backlog row, the design doc, `AGENTS.md`, `docs/README.md`, the feature docs and code the item touches, and `docs/devops.md` if it's operational. For an `idea` with no doc, it writes a first draft of the doc with the feature doc sections (see [../README.md](../README.md#writing-a-feature-doc)), then continues.
2. **Checks the doc against the Definition of Ready** (below). It notes each item as pass, fail, or not applicable, with a reason.
3. **Asks the user** about anything it can't settle from the repo. It asks all its questions at once, gives a recommended answer for each, and waits. It writes each answer into the doc: in the section it belongs to, and in "Decisions made for this ticket" if it was a choice. It never guesses at anything that changes the scope or the behavior.
4. **Proposes a split** if the item fails the size check. Each part becomes its own backlog item, with its own doc and acceptance checks, and with the order and dependencies between the parts noted. It splits only with the user's agreement, and then refines each part separately.
5. **Gets an independent review.** A fresh agent with no context from this conversation reviews the doc against the Definition of Ready and looks for gaps, ambiguities, and missing acceptance checks. If one is available, it should be a different model or a different agent, such as Codex for a doc refined by Claude Code. Each finding is fixed in the doc, or answered with the reason it stays, just like a PR finding. After the fixes, the reviewer runs again. After three rounds with findings still coming, the skill stops and asks the user.
6. **Asks the user for approval.** When the doc passes the checklist and the review has nothing left, the skill shows the user:
   - a short summary of the ticket
   - the checklist results
   - what changed in the doc, and the questions and answers
   - the review findings, and what was done about each

   Then it asks: "Mark it ready?"
7. **Marks it ready, only if the user says yes**, on a branch and in a PR. That PR gives the ticket the next free number, renames the doc to `NNN-<slug>.md`, and sets the row's number, link, and status. It uses `scripts/ticket.sh ready` if that command exists by then (see the backlog), and the manual steps from "How it works" otherwise. The user merges the PR, so the ticket becomes `ready` on `main` only through the user. If the user says no, or asks for changes, the skill keeps the doc `designed`, makes the changes, and goes back to step 2.

At any step, the user can stop. The doc keeps whatever was settled so far, and the status stays `designed`.

## The Definition of Ready

Added as a section of `docs/backlog/README.md`. A ticket is ready when:

1. **Purpose:** the summary says what problem it solves, for whom, and what changes for users or operators. It also says what doesn't change.
2. **Scope:** what's in and what's out is explicit. Anything left for later is a separate backlog row or a known gap, not a vague "maybe".
3. **Fits one PR:** one branch, one reviewable PR, one behavior change that can ship on its own. A rough guide: if the implementation map touches more than about three areas (app, server, CI, infra), or the acceptance checks fall into groups that could each ship alone, split it.
4. **Enough information to build it without asking:**
   - every endpoint, table, setting, message, and error code it adds or changes, with exact values
   - the files in the implementation map exist, or are clearly new files
   - links to the feature docs it changes
   - prerequisites, especially steps only the user can do (settings, secrets, rulesets), and the order they happen in
5. **Acceptance checks:** each one is a concrete scenario with an input or setup and an observable expected result. Each one says how it's verified: an automated test, a CI job, or a manual step. They cover the failure paths and edge cases, not just the happy path. No check uses words like "works", "fast", or "secure" without saying what's measured.
6. **The project's rules** (`AGENTS.md`) are addressed where they apply. For example:
   - attempt limits (rule 1)
   - more than one instance (rule 2): shared state, and migrations or jobs run by several instances at once
   - docs updated in the same PR (rule 3)
   - versions left to release-please (rule 4)
   - workflow permissions and triggers (rule 5)
7. **Security and failure modes:** who can trigger it, what happens when a dependency is down, and what's logged. It also lists the known gaps.
8. **No open questions.** Choices are written down in "Decisions made for this ticket", with the reason for each.

## Readiness review section

The skill records its work in a new section of the design doc, **Readiness review**, like "Delivery and review" records the build:
- the date, and the checklist results
- the questions asked, and the user's answers
- each review round: who reviewed, what was found, and what was done about it
- the user's approval

That way, a ticket's history shows why it was considered ready. Item 9 of "Writing a feature doc" in `docs/README.md` describes the section.

## Security and configuration

- The skill only edits docs: the design doc, the backlog, and `docs/README.md`. It doesn't change code or settings.
- Only the user's approval leads to `ready`, and only the user's merge puts it on `main`. The backlog's "Who sets it" column changes from "The user, in a PR to `main`" to "The user decides. An agent may make the edit after the user approves, in a PR the user merges." `AGENTS.md`'s "Only the user marks tickets `ready`" changes the same way.
- The independent reviewer gets read-only access: it reports findings, and the refining agent makes the edits.

## Implementation map

- `.agents/skills/refine-ticket/SKILL.md`: the skill. It follows the Skills section of `AGENTS.md`: Claude Code finds it through the `.claude/skills` symlink, and Codex and opencode read it directly.
- `docs/backlog/README.md`:
  - a "Definition of Ready" section
  - a link to the skill next to the `next-ticket` link
  - the updated "Who sets it" text
  - a "Refining it" step in "How it works", between designing an item and marking it ready
- `docs/README.md`: item 9 of "Writing a feature doc", **Readiness review**.
- `AGENTS.md`: the `refine-ticket` skill in "Backlog tickets", the updated rule about who marks tickets `ready`, and the Definition of Ready as context for reviewers.

## Acceptance checks

1. `claude`, `codex`, and `opencode`, each run in the repo, list the `refine-ticket` skill.
2. Run on the existing `designed` item "Delete expired session rows", the skill:
   - produces checklist results for all 8 items
   - asks the user any questions in a single batch, and writes the answers into the doc
   - runs at least one independent review with a fresh agent, and records the findings and what was done about them in a "Readiness review" section
   - then asks the user to approve
3. If the user says no, the item stays `designed`, and the doc and the row on `main` don't change status.
4. If the user says yes, the skill opens a PR that gives the item the next free number, renames the doc, and sets the row to `ready`. After the user merges it, `scripts/ticket.sh list` shows the ticket as `ready`.
5. Run on an `idea` row with no design doc, the skill first writes a draft doc with the feature doc sections, then refines it.
6. Run on an item that is too big, for example a made-up "OpenTelemetry for the server and the app" with no design, the skill proposes a split into separate items with an order. With the user's agreement, it adds them to the backlog.
7. The skill never sets a status to `ready` without the user's yes in the same conversation, and never merges a PR.
8. The Definition of Ready section exists in `docs/backlog/README.md`. `AGENTS.md`, the backlog README, and `docs/README.md` describe the skill and the Readiness review section, and their wording about who marks tickets `ready` matches.

## Decisions made for this ticket

Change these before marking it ready if you disagree:
- **The Definition of Ready lives in the backlog README, not in the skill,** so people and other reviewers see the same list, and changing it doesn't mean changing a skill.
- **The skill can make the `ready` edit, but only after the user's explicit yes, and only in a PR the user merges.** This keeps the user's decision and lets the agent do the bookkeeping. The rule's wording changes to say so.
- **At most three independent review rounds** before the user is asked. It keeps the loop from running forever on a ticket that's not converging.
- **A different model for the independent review where possible.** It's not required: a fresh agent of the same model with no shared context is still independent.
