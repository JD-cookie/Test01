# Backlog

Feature and work requests that aren't built yet. This file is the project's ticket system: each item is one row, its history is this file's git history, and each ticket becomes one branch and one PR.

**Agents: pick up work with the `next-ticket` skill, [`.claude/skills/next-ticket/SKILL.md`](../../.claude/skills/next-ticket/SKILL.md).** It uses [`scripts/ticket.sh`](../../scripts/ticket.sh) to list the ready tickets and to claim one. Agents other than Claude Code follow the same steps: see "Backlog tickets" in [`AGENTS.md`](../../AGENTS.md#backlog-tickets).

## Statuses

| Status | Meaning | Who sets it |
|---|---|---|
| `idea` | A row, no design doc yet | Anyone |
| `designed` | Has a design doc, `docs/backlog/<slug>.md`, but it isn't ready to build | Anyone |
| `ready` | Has a **number** and a design doc `docs/backlog/NNN-<slug>.md` with acceptance checks, and fits in one PR. Agents only pick up `ready` tickets. | **The user**, in a PR to `main` |
| `in progress (claim …)` | Claimed by an agent. This status is only on the ticket's branch: it reaches `main` with the PR, which removes the row anyway. | `scripts/ticket.sh claim` |

## How it works

- **Adding an item:** add a row with status `idea`. Leave the `#` column empty. A design doc is optional at first.
- **Designing an item:** write `docs/backlog/<slug>.md`, for example `password-reset.md`, link the title to it, and set the status to `designed`. Use the same sections as a feature doc (see [../README.md](../README.md#writing-a-feature-doc)), and fill in as much as is known.
- **Marking it ready (the user):** give it the next free number. That is one more than the highest number in this table and in [`docs/features/`](../features/). Rename its doc to `NNN-<slug>.md`, check that the doc has acceptance checks and no open questions, and set the status to `ready`. Numbers are given out one at a time, on `main`, so two agents working in parallel can never take the same one. The ticket's branch is named `NNN-<slug>`.
- **Claiming it (an agent):** `scripts/ticket.sh claim NNN-<slug> <agent-name>`. Whoever creates the ticket's branch on `origin` first holds the claim, and everyone else is turned away. No merge is needed. To see what's free: `scripts/ticket.sh list`.
- **Building it,** on its branch, in its PR:
  1. Move the design doc to `docs/features/NNN-<slug>.md` and bring it up to date with what was built, including a **Delivery and review** section (see [../README.md](../README.md#writing-a-feature-doc)).
  2. Add it to the Features table in [../README.md](../README.md#features).
  3. Delete its row here.
  4. Update any links to the old path.
- **Releasing a claim** (only the user): delete the ticket's branch on `origin`. The ticket is free again, because on `main` it still says `ready`.
- **Dropping an item:** delete the row and its design doc, and note why in the commit message.
- **Order:** rows are roughly in priority order, highest first. Agents take the first free `ready` ticket unless told otherwise. Reorder freely.

## Items

| # | Item | Area | Status | Notes |
|---|---|---|---|---|
| 003 | [Delete expired session rows](003-delete-expired-sessions.md) | Server | ready | Housekeeping only: expired sessions are already rejected. Gap from [001](../features/001-accounts.md#security). |
| 004 | [Container image for the server](004-server-container-image.md) | DevOps | ready | A `Containerfile` built with podman. CI builds and smoke-tests it on every PR, and each server release made by release-please publishes it to GHCR. Needs a tag ruleset from the user first. The first step toward CD and Kubernetes. |
|  | Decide what the app does beyond accounts | Product | idea | The project is for learning, so pick features that give the technology below real work to do: data worth tracing, deploys worth automating. |
|  | OpenTelemetry | Observability | idea | Traces, metrics, and logs from the server, and maybe from the app too. Needs a collector and somewhere to view the data. Not designed yet. |
|  | Local Kubernetes cluster | DevOps | idea | Suggested: k3s on the dev machine. It's a full Kubernetes distribution with its own container runtime, so it doesn't need Docker. Podman-built images run on it unchanged. Staging would run here. |
|  | GitOps deploys (CD) | DevOps | idea | The desired state of each environment is declared in git, and a tool in the cluster, Argo CD or Flux, applies it automatically. Depends on the server image, CI, and the cluster. Not designed yet. |
|  | Password reset | Accounts | idea | Needs a way to send email, shared with email verification. Gap from [001](../features/001-accounts.md#security). |
|  | Email verification | Accounts | idea | Needs a way to send email, shared with password reset. Gap from [001](../features/001-accounts.md#security). |
|  | Staging/production database and Valkey | Server, DevOps | idea | Choose the database. Add a database layer so SQLite (development and tests) and the server database share one code path. Make migrations portable, and run them once per deploy rather than on each instance's startup. Run the test suite against both databases. Run Valkey for staging and production and set `VALKEY_URL` there; the server already supports it (see [002](../features/002-rate-limiting.md)). Needed before running more than one server instance. See [../devops.md](../devops.md#environments). |
|  | Production hosting with HTTPS | DevOps | idea | Choose a host, then set the production `API_URL`. See [../devops.md](../devops.md). |
|  | HTTPS for development and staging | DevOps, security | idea | Both use plain HTTP on the LAN today. Gap from [001](../features/001-accounts.md#security). |
|  | Login challenge (CAPTCHA) after many failures for one account | Server, security | idea | Covers the gap left by [002](../features/002-rate-limiting.md#security): a distributed attack on one account from many networks. |
|  | Run the app in a web browser for UI work | Dev tooling | idea | Optional. SecureStore has no web version, so this needs a development-only fallback, plus `react-native-web` and `react-dom`. |
|  | Over-the-air updates (EAS Update) | DevOps | idea | Right now every app change needs a new APK. See [../devops.md](../devops.md#known-gaps-and-caveats). |
|  | iOS build profile | DevOps | idea | Bundle IDs exist already. Needs an Apple Developer account. See [../devops.md](../devops.md#known-gaps-and-caveats). |
