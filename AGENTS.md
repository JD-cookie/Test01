# AGENTS.md

Instructions for AI agents and reviewers working in this repository. People are welcome to read it too.

## Project

**Test01** is a mobile app (Expo / React Native, Android first) with its own backend API (Node 24 + Fastify). It's a learning project for technology the owner hasn't used before: phone apps, CI/CD and GitOps, OpenTelemetry, and more. So things are built the way a production system would build them, even where a shortcut would do for an app this size. When you introduce a technology, explain it briefly.

| Path | What's there |
|---|---|
| `app/` | The mobile app: Expo SDK 58, Expo Router, TypeScript. **Expo-specific instructions are in [`app/AGENTS.md`](app/AGENTS.md).** |
| `server/` | The API: Fastify 5, `node:sqlite` in development and tests, optional Valkey for shared counters. TypeScript run directly by Node (type stripping), so only erasable syntax. |
| `docs/` | The system spec, one doc per feature. Start at [`docs/README.md`](docs/README.md). Environments, config, CI, and releases: [`docs/devops.md`](docs/devops.md). |
| `docs/backlog/README.md` | The ticket system: work not built yet. New requests and known gaps go here. See [Backlog tickets](#backlog-tickets). |
| `scripts/ticket.sh` | Lists the ready tickets and claims one. |
| `.agents/skills/` | Agent skills, such as `next-ticket`. `.claude/skills` is a symlink to it. See [Skills](#skills). |
| `.github/workflows/` | CI (`ci.yml`), the PR title check (`pr-title.yml`), and releases (`release-please.yml`). |
| `STATUS.md` | A handoff note between working sessions: where the work stands. Not a rules file. |

## Setup

```bash
npm install                  # repo root: husky git hooks and commitlint
npm --prefix server install
npm --prefix app install     # app packages: add them with `npx expo install <pkg>`, not npm install
```

Containers use **podman**, not Docker.

## Verify

```bash
npm run check                # everything: the server's typecheck + tests, then the app's typegen + lint + typecheck
npm --prefix server run check
npm --prefix app run check
```

The Valkey store tests are skipped unless `VALKEY_URL` is set. To run them as CI does:

```bash
podman run -d --rm --name test01-valkey -p 127.0.0.1:6379:6379 docker.io/valkey/valkey:9-alpine
VALKEY_URL=redis://127.0.0.1:6379/0 npm --prefix server test
podman stop test01-valkey
```

The `pre-commit` hook runs the matching `check` on the staged content of each part you changed. The `commit-msg` hook runs commitlint. Don't bypass them with `--no-verify`. If a hook fails, fix the cause. CI runs the same checks on every PR, plus actionlint is worth running (`podman run --rm -v "$PWD":/repo:ro -w /repo docker.io/rhysd/actionlint:latest`) before pushing workflow changes.

## Rules

Each rule says where it applies and why it exists. Reviewers should flag changes that break one.

### 1. Count Before You Check

**Rule:** anything that limits attempts must record each attempt atomically, in a single increment that also returns the new count, **before** doing the check it guards (password, code, token). Never read the counter, decide, and write it back later.

**Applies to:** login, signup, and any future limit on guesses or requests, such as password reset or verification codes. In code: `server/src/ratelimit.ts` and the route handlers in `server/src/app.ts` that call `limiter.hit`.

**Why:** Qodo's first review of the rate limiter found that 20 parallel wrong guesses for one account all got past the 5-failure lockout: each request read the counter before any of them had added to it. Counting first, with one atomic `INCR` (Valkey's Lua script, or the in-memory store's synchronous increment), closes that race. `server/test/ratelimit.test.ts` has a test for it: 20 parallel guesses get exactly 5 × 401 and 15 × 429.

### 2. No Shared State in Process Memory

**Rule:** state that has to be the same for every request, such as sessions, rate-limit counters, and caches that must agree, lives in the database or in Valkey, never in a module-level variable or an in-process `Map`. An in-memory implementation is allowed only as the fallback for development and tests, behind the same interface (like `MemoryRateLimitStore`).

**Applies to:** `server/src/`.

**Why:** staging and production will run more than one server instance. State in one process's memory would make each instance behave differently, or quietly require sticky load balancing. SQLite is for development and tests only, so keep SQL portable, too: no SQLite-only features.

### 3. Every Feature Ships With Its Doc

**Rule:** a PR that adds or changes behavior updates the spec in the same PR: `docs/features/NNN-<slug>.md` for a feature, `docs/devops.md` for environments, config, CI, or releases. A feature's number is given when its ticket is marked `ready` in the backlog, and its branch is named after the doc (`003-delete-expired-sessions`). The docs must hold enough detail to rebuild the system from them alone. When a feature built from the backlog is done, its row leaves `docs/backlog/README.md`.

**Applies to:** every PR that touches `app/`, `server/`, or `.github/`. Docs-only, test-only, and release PRs are exempt.

**Why:** the docs are the spec of the system, not a description written afterwards. Docs written later drift from the code, and a later rebuild, or the next agent, can't trust them.

### 4. Release Tooling Owns Versions and Changelogs

**Rule:** don't edit versions or changelogs by hand: the `version` in `server/package.json` and `app/package.json`, `expo.version` in `app/app.json`, `server/CHANGELOG.md`, `app/CHANGELOG.md`, and `.release-please-manifest.json`. release-please changes them in its release PR. Commit messages and PR titles follow Conventional Commits, with scopes `app`, `server`, `docs`, `ci`, `repo`, `deps`, or `release`. A breaking change needs `!` in the **PR title**, e.g. `feat(server)!: …`. To force a version, use `release-as` in `release-please-config.json`.

**Applies to:** every commit and PR. The Android build number (`versionCode`) is EAS's, not ours: `appVersionSource` is `remote`.

**Why:** PRs are squash-merged with the PR title as the commit message, so the title is the only input release-please gets: it picks the version bump and writes the changelog line. A footer like `BREAKING CHANGE:` in a commit body doesn't survive the squash. A version edited by hand breaks release-please's manifest and the tags.

### 5. Least-Privilege Workflows

**Rule:** in GitHub Actions workflows:
- Pin every action to a full commit SHA, with the version in a comment.
- Set `permissions:` at the top to read-only (`contents: read`) or none (`{}`), and grant more only to the job that needs it.
- Never use `pull_request_target`.
- Use `persist-credentials: false` on checkout.
- Pass PR titles, branch names, and other text from the PR to scripts through `env:`, never with `${{ … }}` inside `run:`.
- Keep secrets in environments limited to the branches that need them, like the `release` environment, which only `main` can use. Never let a workflow approve or merge PRs.

**Applies to:** `.github/workflows/`.

**Why:** the repo is public, and workflows are where tokens and secrets are. A moved tag can swap in different code for an action. Text from a PR spliced into a script is shell injection. The release App's key in a `main`-only environment can't be read by a workflow pushed on another branch. These are the reasons release-please uses a GitHub App instead of turning on "Allow GitHub Actions to create and approve pull requests".

## Backlog tickets

Work comes from [`docs/backlog/README.md`](docs/backlog/README.md), which defines the statuses and the lifecycle of a ticket. Several agents may work at once, so:

- **Only build a `ready` ticket.** Such a ticket has a number and a design doc, `docs/backlog/NNN-<slug>.md`, with acceptance checks. Only the user marks tickets `ready`.
- **Claim it before starting:** run `scripts/ticket.sh claim NNN-<slug> <agent-name>`.
  - The claim is the ticket's branch on `origin`, named `NNN-<slug>`. The script creates it with a unique claim commit, pushes it create-only, and checks that `origin` has that commit. Only one agent can win, and no merge is needed.
  - Exit code 3 means another agent has the ticket. Take the next one from `scripts/ticket.sh list`.
  - Never delete, overwrite, or force-push another agent's branch. Only the user releases a claim.
- **One ticket per branch and PR.** The PR moves the design doc to `docs/features/` and fills in its "Delivery and review" section. It also deletes the ticket's row and adds the feature to `docs/README.md`.

These steps are the `next-ticket` skill: [`.agents/skills/next-ticket/SKILL.md`](.agents/skills/next-ticket/SKILL.md). See [Skills](#skills) for where agents find it.

## Skills

A skill is a folder with a `SKILL.md`: a name, a description that tells the agent when to use it, and the steps. The format is the open [Agent Skills](https://agentskills.io) standard, so one copy works in every agent:

- **`.agents/skills/<name>/SKILL.md`** is where skills live. Codex and opencode read this folder.
- **`.claude/skills`** is a symlink to `.agents/skills`, because Claude Code reads only `.claude/skills`. opencode reads both and finds the same skill once.

Add new skills under `.agents/skills/`, never as a real folder in `.claude/skills/`. An agent that reads neither folder can still follow a skill: it's plain Markdown.

## Working in this repo

- Branch from `main` and open a PR. Don't push to `main` directly. PRs get a Qodo review, and every finding is either fixed or answered with the reason.
- Keep `STATUS.md` up to date while working: it's how the next session picks up where this one stopped.
- Never commit secrets. Configuration is in environment variables (`server/.env` locally, which is git-ignored). See `docs/devops.md`.
