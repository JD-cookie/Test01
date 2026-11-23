# Test01 system documentation

Test01 is a learning project: a realistic mobile app and backend for exploring phone apps, GitOps, OpenTelemetry, and other technology (see the [top-level README](../README.md)).

These documents are the **specification** of Test01. Together they hold enough detail to rebuild the system from scratch, in any technology. A rebuilt version needn't look identical, but it should behave the same way, so someone who has used the original would find it familiar.

The spec and the history of how it was built are kept apart:
- **Spec docs** say what the system does now: this file, [devops.md](devops.md), and one doc per capability in `features/`. A change to a capability edits its doc in place, and each spec doc ends with a **Changes** list of the tickets that changed it.
- **Ticket docs**, in `tickets/`, are the history: one doc per built ticket, with how it was refined, what was built, and how it was checked. The index is [tickets/README.md](tickets/README.md).

## Architecture

```
┌──────────────────────┐     HTTP + JSON      ┌───────────────────────┐
│  Mobile app           │  ─────────────────▶  │  Backend API          │
│  (Android now, iOS    │   Bearer token auth  │  (single process)     │
│   later)              │  ◀─────────────────  │                       │
│  Secure storage for   │                      │  Relational database  │
│  the session token    │                      │                       │
└──────────────────────┘                      └───────────────────────┘
```

- **The client** is a single cross-platform mobile app. Its whole state comes from the API, except for the cached session.
- **The server** is a stateless HTTP API with a single relational database: SQLite in development, a database server in staging and production. State shared between server instances goes in Valkey, never in process memory. See [devops.md](devops.md#environments). Every rule is enforced on the server. The client repeats some checks only to give quicker feedback.
- **API conventions**, which every feature follows:
  - Paths start with `/api/v1/`. The version only changes for breaking changes; see [devops.md](devops.md).
  - Every request from the app sends `X-App-Version`. Apps older than the server's minimum get `426 UPGRADE_REQUIRED`.
  - Bodies are JSON.
  - Authenticated requests send `Authorization: Bearer <token>`.
  - Errors look like `{"error":{"code","message","field?"}}`, where `message` is safe to show to users and `field` names the form input it concerns.
  - Timestamps are ISO 8601 UTC strings, and IDs are UUIDs.
  - JSON uses camelCase; database columns use snake_case.

## Operations

[devops.md](devops.md) covers the environments (test, development, staging, production), the app and server settings, API versioning and app compatibility, database changes, version numbers and releases (Conventional Commits and release-please), CI, and how to build and deploy.

## Features

| # | Feature | Status |
|---|---|---|
| 0001 | [Accounts: sign up, log in, stay logged in, log out](features/0001-accounts.md) | Implemented |
| 0002 | [Rate limiting of login and signup](features/0002-rate-limiting.md) | Implemented |
| 0003 | [A skill that gets a ticket ready to build](features/0003-refine-ticket-skill.md) | Implemented |
| 0007 | [A runner that builds a ready ticket into a PR](features/0007-agent-runner.md) | Implemented (part 1 of 3) |

Work that isn't built yet, with any design docs written for it, is tracked in [backlog/README.md](backlog/README.md), which works as the ticket system. An item gets its number when it's marked `ready`, so its branch name `NNNN-<slug>` is known in advance. In the PR that builds it, its design doc moves from `backlog/` into `tickets/`, and the PR writes or edits the spec docs. A new capability gets a spec doc in `features/` with the ticket's number, so this folder's numbers have gaps.

## Writing a feature doc

There are two kinds of doc: spec docs, which describe the system now, and ticket docs, which record one change.

### A spec doc's sections

A new capability gets a numbered file in `features/`, written **in the same change** that builds it. Changing a capability means editing its doc in place, in that change too. Each doc covers:

1. **Summary** and **concepts**: what the feature is for and the terms it introduces
2. **User-facing behavior**, screen by screen: what's on each screen, every validation rule and its exact message, loading, empty, and error states, and where each action leads
3. **API**: each endpoint with its request, response, processing order, and error codes
4. **Data model**: tables, columns, constraints
5. **Security and configuration**, plus known gaps
6. **Implementation map**: where the feature lives in the current code. This is the only section tied to the current technology.
7. **Acceptance checks**: concrete scenarios a rebuilt version has to pass
8. **Changes**, at the end: one line per ticket that changed it, oldest first: `- NNNN: <title> ([ticket](../tickets/NNNN-<slug>.md))`. From this file and `devops.md`, the path is `tickets/NNNN-<slug>.md`.

A spec doc has no decisions section: the reasons are in the ticket docs its Changes list links. This file and `devops.md` keep their own structure, and end with a Changes section too.

**A spec doc is never renamed or deleted** once the PR that adds it has merged, so links to it keep working: from ticket docs, which aren't edited, and from the release changelogs, which can't be edited by hand (rule 4 in `AGENTS.md`). A design doc in `backlog/` can be renamed until then. When a ticket removes a capability, its spec doc is cut to a stub: the title, `Status: removed`, the date, the ticket that removed it, and its Changes list. When a spec doc's content moves into another, it's cut to a stub the same way, with `Status: merged into <spec doc>`, linked. Its number stays used either way.

### A ticket doc's sections

A ticket's design doc is written in `backlog/` and moves to `tickets/` in the PR that builds it, updated to what was built. It's **frozen** once that PR merges: it isn't edited after, links included. Whatever happens later, such as a check that can only run after the merge, goes in a later ticket's doc, which links back. It has:

- the spec sections above (1 to 7) for the part of the system it changes: a snapshot of them as built, on the day its PR merged
- a status line that says built, with the date, and after it a **Spec docs changed** line, linking each spec doc it changed
- **Readiness review**: for tickets refined with the `refine-ticket` skill, written before the ticket is marked `ready`. The goal as restated, the checks that the work is needed, the results of the [Definition of Ready](backlog/README.md#definition-of-ready), the questions asked and the user's answers, each independent review round (who reviewed, with which model, their restatement, each finding with whether it's blocking or minor, its evidence, and what was done about it), and the user's approval.
- **Decisions made for this ticket**: each choice, with the reason.
- **Delivery and review**: which acceptance checks passed and how they were checked, what changed from the version marked ready and why, what the PR review found and what was done about each finding, and whether it led to a change in the rules (`AGENTS.md`), the skills, or the context reviewers get.

**Stable links.** A ticket doc in `tickets/` keeps only links that can't break once it's frozen:
- to a spec doc, by file only, never to a section (`#…`), since headings change
- to another doc in `tickets/`, with or without a section, since both are frozen
- to anything else that's on `main`, such as a design doc still in `backlog/`, a skill, or code, as a GitHub permalink: `https://github.com/JD-cookie/Test01/blob/<sha>/<path>`, with an optional `#…`. `<sha>` is the newest commit on `main` that has the file at that path, with the heading if the link has one. To find it, go through `git log --format=%H origin/main -- <path>` newest first: for a commit that has the file, take it if the link has no heading, or if `git show <commit>:<path>` has the heading; for a commit that deleted or moved the file, try its parent. If no commit on `main` has the heading, for example because the ticket's own PR adds it, drop the `#…`.
- a file that the ticket's own PR adds isn't on `main` yet, so it's named as plain text instead, as an implementation map does. Plain-text paths aren't links.

## Changes

- 0003: A skill that gets a ticket ready to build ([ticket](tickets/0003-refine-ticket-skill.md))
- 0006: Keep the spec separate from the ticket history ([ticket](tickets/0006-spec-and-tickets.md))
- 0007: A runner that builds a ready ticket into a PR ([ticket](tickets/0007-agent-runner.md))
