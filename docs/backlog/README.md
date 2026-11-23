# Backlog

Feature and work requests that aren't built yet. This file is the project's ticket system: each item is one row, its history is this file's git history, and each ticket becomes one branch and one PR.

**Agents: pick up work with the `next-ticket` skill, [`.agents/skills/next-ticket/SKILL.md`](../../.agents/skills/next-ticket/SKILL.md).** It uses [`scripts/ticket.sh`](../../scripts/ticket.sh) to list the ready tickets and to claim one. To get an item ready to build, use the `refine-ticket` skill, [`.agents/skills/refine-ticket/SKILL.md`](../../.agents/skills/refine-ticket/SKILL.md). Claude Code, Codex, and opencode all find both as skills. Any other agent follows the same file: see "Backlog tickets" in [`AGENTS.md`](../../AGENTS.md#backlog-tickets).

## Statuses

| Status | Meaning | Who sets it |
|---|---|---|
| `idea` | A row, no design doc yet | Anyone |
| `designed` | Has a design doc, `docs/backlog/<slug>.md`, but it isn't ready to build | Anyone |
| `ready` | Has a **number** and a design doc `docs/backlog/NNNN-<slug>.md` that meets the [Definition of Ready](#definition-of-ready). Agents only pick up `ready` tickets. | **The user decides.** An agent may make the edit after the user approves, in a PR the user merges. |
| `in progress (claim …)` | Claimed by an agent. This status is only on the ticket's branch: it reaches `main` with the PR, which removes the row anyway. | `scripts/ticket.sh claim` |

## How it works

- **Adding an item:** add a row with status `idea`. Leave the `#` column empty. A design doc is optional at first.
- **Designing an item:** write `docs/backlog/<slug>.md`, for example `password-reset.md`, link the title to it, and set the status to `designed`. Use the same sections as a feature doc (see [../README.md](../README.md#writing-a-feature-doc)), and fill in as much as is known.
- **Refining it:** run the `refine-ticket` skill on the item. It checks the doc against the [Definition of Ready](#definition-of-ready), asks the user about the open decisions, proposes a split if it's too big, and gets an independent review. It records all of that in the doc's **Readiness review** section, then asks the user to approve.
- **Marking it ready (the user decides):** give it the next free number, four digits, zero-padded (`0007`). That is one more than the highest number in this table, in [`docs/features/`](../features/), and in the names of the `NNNN-*` and `ready-NNNN` branches on `origin`. Rename its doc to `NNNN-<slug>.md`, check that it meets the Definition of Ready, and set the status to `ready`, in one PR on a branch named `ready-NNNN`. Push that branch create-only (`git push --force-with-lease=refs/heads/ready-NNNN: …`): if it already exists, another ready PR holds the number, so take the next one. Each number then reaches `main` only once, so two agents working in parallel can never take the same one. The user can do this by hand, or approve it in `refine-ticket`, which does it. The ticket's branch is named `NNNN-<slug>`.
- **Claiming it (an agent):** `scripts/ticket.sh claim next <agent-name>` claims the first free `ready` ticket, and `claim NNNN-<slug>` claims a named one. Whoever creates the ticket's branch on `origin` first holds the claim, and everyone else is turned away. No merge is needed. To see what's free: `scripts/ticket.sh list`.
- **Building it,** on its branch, in its PR:
  1. Move the design doc to `docs/features/NNNN-<slug>.md` and bring it up to date with what was built, including a **Delivery and review** section (see [../README.md](../README.md#writing-a-feature-doc)).
  2. Add it to the Features table in [../README.md](../README.md#features).
  3. Delete its row here.
  4. Update any links to the old path.
- **Releasing a claim** (only the user): delete the ticket's branch on `origin`. The ticket is free again, because on `main` it still says `ready`.
- **Dropping an item:** delete the row and its design doc, and note why in the commit message.
- **Order:** rows are roughly in priority order, highest first. Agents take the first free `ready` ticket unless told otherwise. Reorder freely.
- **Blocked items:** an item that can't start until others are built begins its Notes with "Blocked by: …", naming those items by title. Don't mark it `ready` until they're built.

## Definition of Ready

A ticket is ready to build when its design doc meets every item that applies. The `refine-ticket` skill checks each one, and reviewers can use the same list.

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
8. **The project's rules** ([`AGENTS.md`](../../AGENTS.md#rules)) are addressed where they apply. For example:
   - attempt limits (rule 1)
   - more than one instance (rule 2): shared state, and migrations or jobs run by several instances at once
   - docs updated in the same PR (rule 3)
   - versions left to release-please (rule 4)
   - workflow permissions and triggers (rule 5)
9. **Security and failure modes:** who can trigger it, what happens when a dependency is down, and what's logged. It also lists the known gaps.
10. **No open questions.** Choices are written down in "Decisions made for this ticket", with the reason for each.

## Items

| # | Item | Area | Status | Notes |
|---|---|---|---|---|
| 0004 | [Delete expired session rows](0004-delete-expired-sessions.md) | Server | ready | Housekeeping only: expired sessions are already rejected. Gap from [0001](../features/0001-accounts.md#security). |
| 0006 | [Keep the spec separate from the ticket history](0006-spec-and-tickets.md) | Docs | in progress (claim 8a067552, claude-00cb8987, 2026-11-23T03:22Z) | `docs/features/` becomes the living spec, edited in place by each ticket, with a Changes list. A built ticket's doc moves to `docs/tickets/`, as history, instead of `docs/features/`. Before the runner's part 1 is built. |
|  | [A runner that builds a ready ticket into a PR](agent-runner.md) | Dev tooling | designed | Blocked by: Keep the spec separate from the ticket history. Part 1 of 3, split from "An agent that builds ready tickets on a timer". `scripts/agent-run.sh`, run by hand: claims the next `ready` ticket, builds it with `claude -p`, gets the checks green in a `bwrap` sandbox (3 tries), and opens the PR as the App `jd-cookie-agent[bot]`, or a draft PR with `needs-help`. The user takes the PR through review and merges. |
|  | [The runner fixes Qodo's findings on its PRs](agent-review-rounds.md) | Dev tooling | designed | Blocked by: A runner that builds a ready ticket into a PR. Part 2 of 3. On each commit Qodo reviews, the runner runs a round: the agent fixes or answers Qodo's findings, the owner's comments, and failed CI jobs, and the runner pushes and replies. Up to 4 rounds, then `needs-help`. |
|  | [Start the runner on a timer](agent-timer.md) | Dev tooling | designed | Blocked by: A runner that builds a ready ticket into a PR; The runner fixes Qodo's findings on its PRs. Part 3 of 3. A systemd user timer runs the runner every 15 minutes, set up by `scripts/agent-timer.sh install`. Its real run, on ticket 004, is Day 4 of the hackathon. |
|  | Run the runner's agent as its own Linux user | Dev tooling | idea | Blocked by: A runner that builds a ready ticket into a PR. The runner's agent runs as the user, so it can read the App key, the user's `gh` token, and the deploy key (a known gap in [agent-runner.md](agent-runner.md)). Running it as a separate user, `jd-cookie-agent`, lets the OS hide them. Needs `sudo` once, a sudoers rule for the runner, and a `claude login` as that user. |
|  | A credential broker for the runner | Dev tooling | idea | Blocked by: Run the runner's agent as its own Linux user. A small service, as its own Linux user, that holds the App key and does only the runner's GitHub actions (push a claimed branch, open a PR, comment, label), so nothing the agent can reach holds a key. The way a production system holds credentials, for example with Vault. |
|  | The runner waits out Claude's usage limit | Dev tooling | idea | Blocked by: A runner that builds a ready ticket into a PR. When the runner's agent hits Claude's 5-hour or weekly usage limit, the runner stops for help today (see [agent-runner.md](agent-runner.md)). Instead, it would record the reset time, have later runs exit early until then, and then go on with the same build or round without the user. Needs a way for a build to resume across runs: today a run that dies mid-build always stops for help. |
|  | Mark a blocked ticket `ready` before its blockers are built | Dev tooling | idea | Blocked by: Keep the spec separate from the ticket history. Today an item with "Blocked by: …" can't be marked `ready` until what blocks it is built ("How it works", and `refine-ticket` steps 8 and 9.1), so a design the user has approved waits, and the user has to come back for a second ready PR. Instead: the user marks it `ready` once, when they approve it, and its row keeps its "Blocked by". `scripts/ticket.sh` (`list`, `claim next`, `claim NNNN-slug`) skips a `ready` ticket until each blocker is built, by ticket 0006's rule (its row is gone, and it's in `docs/tickets/README.md`), and `list` shows what it waits on. Nothing changes the status later, so only the user still marks tickets `ready`. Raised by [A runner that builds a ready ticket into a PR](agent-runner.md), approved on 2026-11-22 while 0006 wasn't built. |
|  | Code reviews by our own agents | Dev tooling | idea | Have Claude Code, Codex, or opencode review each PR too, beside Qodo, for example with the reviewer setup of the `refine-ticket` skill. First look for good existing code-review skills or commands to reuse rather than writing one: Claude Code's `/code-review` and `/security-review`, Codex's review mode, and published Agent Skills. The runner's rounds could then include their findings. |
|  | [Container image for the server](server-container-image.md) | DevOps | designed | A `Containerfile` built with podman. CI builds and smoke-tests it on every PR, and each server release made by release-please publishes it to GHCR. Needs a tag ruleset from the user first. The first step toward CD and Kubernetes. |
|  | Ticket commands for the user: `new` and `ready` | Dev tooling | idea | Add two commands to `scripts/ticket.sh` for the steps in "How it works" that are fiddly by hand. `new <slug> "<title>"` adds an `idea` row and creates `docs/backlog/<slug>.md` with the feature doc sections (see [../README.md](../README.md#writing-a-feature-doc)). `ready <slug>` runs on a branch from an up-to-date `main`. It gives the ticket the next free number, renames the doc with `git mv`, and updates the row's number, link, and status. It checks that the doc has acceptance checks, and makes one commit for a PR. Two `ready` PRs open at once could pick the same number, so `ready` reserves it with a create-only `ready-NNNN` branch, the PR's branch, and takes the next number if that branch exists. See [refine-ticket-skill.md](../features/0003-refine-ticket-skill.md). Adding, editing, reordering, and dropping rows stay plain edits. |
|  | Weigh likelihood in refine-ticket reviews | Dev tooling | idea | Its stop rule ends only after a round with no blocking findings, and "blocking" doesn't weigh how likely a case is, so an adversarial reviewer can keep finding rarer ones. [Keep the spec separate from the ticket history](0006-spec-and-tickets.md) took 7 rounds, most of them on a case that didn't exist. Ideas: severity weighs likelihood; a case the doc handles with "stop and ask the user" is an answer, not a gap; the review prompt stops asking for concurrency and edge cases the doc rules out. Also: step 9.6 prints `error: no row on main` for an item whose row the ready branch itself adds (ticket 0006, 2026-11-20); it should accept that. Change `.agents/skills/refine-ticket/` and 0003's spec. |
|  | Decide what the app does beyond accounts | Product | idea | The project is for learning, so pick features that give the technology below real work to do: data worth tracing, deploys worth automating. |
|  | OpenTelemetry | Observability | idea | Traces, metrics, and logs from the server, and maybe from the app too. Needs a collector and somewhere to view the data. Not designed yet. |
|  | Signed build provenance for images | DevOps, security | idea | After the server image. Have the publish job attest each image (`actions/attest-build-provenance`), and have the cluster only run images whose provenance checks out. Then an image proves it was built by the release workflow from a release tag, rather than relying on who can push to GHCR. Anyone with write access can push today; see [Container image for the server](server-container-image.md#security-and-configuration). |
|  | Local Kubernetes cluster | DevOps | idea | Suggested: k3s on the dev machine. It's a full Kubernetes distribution with its own container runtime, so it doesn't need Docker. Podman-built images run on it unchanged. Staging would run here. |
|  | GitOps deploys (CD) | DevOps | idea | The desired state of each environment is declared in git, and a tool in the cluster, Argo CD or Flux, applies it automatically. Depends on the server image, CI, and the cluster. Not designed yet. |
|  | Password reset | Accounts | idea | Needs a way to send email, shared with email verification. Gap from [0001](../features/0001-accounts.md#security). |
|  | Email verification | Accounts | idea | Needs a way to send email, shared with password reset. Gap from [0001](../features/0001-accounts.md#security). |
|  | Staging/production database and Valkey | Server, DevOps | idea | Choose the database. Add a database layer so SQLite (development and tests) and the server database share one code path. Make migrations portable, and run them once per deploy rather than on each instance's startup. Run the test suite against both databases. Run Valkey for staging and production and set `VALKEY_URL` there; the server already supports it (see [0002](../features/0002-rate-limiting.md)). Needed before running more than one server instance. See [../devops.md](../devops.md#environments). |
|  | Production hosting with HTTPS | DevOps | idea | Choose a host, then set the production `API_URL`. See [../devops.md](../devops.md). |
|  | HTTPS for development and staging | DevOps, security | idea | Both use plain HTTP on the LAN today. Gap from [0001](../features/0001-accounts.md#security). |
|  | Login challenge (CAPTCHA) after many failures for one account | Server, security | idea | Covers the gap left by [0002](../features/0002-rate-limiting.md#security): a distributed attack on one account from many networks. |
|  | Run the app in a web browser for UI work | Dev tooling | idea | Optional. SecureStore has no web version, so this needs a development-only fallback, plus `react-native-web` and `react-dom`. |
|  | Over-the-air updates (EAS Update) | DevOps | idea | Right now every app change needs a new APK. See [../devops.md](../devops.md#known-gaps-and-caveats). |
|  | iOS build profile | DevOps | idea | Bundle IDs exist already. Needs an Apple Developer account. See [../devops.md](../devops.md#known-gaps-and-caveats). |
