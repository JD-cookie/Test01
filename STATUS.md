# Project status

Last updated 2026-11-17. This is a handoff note between working sessions. The system spec is in `docs/`; this file tracks where the work stands. Keep one fact or next step per line, so updates change a line rather than rewrite a paragraph.

## Where things are

- **Qodo hackathon** ("Build a Software Factory in 30 Days", 2026-11-02 to 2026-12-02). The user is entering with this project.
  - 23 weekday challenges. Missed ones can be caught up before the final cutoff, midnight Pacific at the end of Dec 2.
  - Each challenge gets a focused branch and PR with a Qodo review. The user posts each submission in that challenge's Discussion.
  - Rules: https://hackathon.qodo.ai/rules/. Submission template: https://github.com/orgs/qodo-hackathon/discussions/1.
- **Day 1** (rate limiting, feature 002): https://github.com/orgs/qodo-hackathon/discussions/2
  - Merged in PR #1 (https://github.com/JD-cookie/Test01/pull/1).
  - Done: the user posted a screen capture in the Discussion (2026-11-17).
- **Day 2** (AGENTS.md with 3–5 rules, imported into Qodo as Review Standards, and one rule nominated in the Day 2 Discussion):
  - Merged in PR #5 (2026-11-13): https://github.com/JD-cookie/Test01/blob/main/AGENTS.md.
  - Done: the user confirmed Qodo's Review Standards have the five rules (2026-11-17).
  - **Next (user):** post the nomination in the Day 2 Discussion. Suggested: "Count Before You Check", from Qodo's Day 1 finding.
- **Day 3** (connect the backlog to the agent, and work tickets one per branch and PR). The user chose to keep the backlog in the repo rather than an external tracker.
  - PR #7 (merged 2026-11-16): the backlog is the ticket system, with a `ready` status, a number given when a ticket is marked ready, and claims made by creating the ticket's branch. Adds `scripts/ticket.sh` (`list`, `claim next`, `claim NNN-slug`, `verify`) and the `next-ticket` skill (in `.agents/skills/`, with `.claude/skills` a symlink to it, so Claude Code, Codex, and opencode all find it).
  - PR #8 (merged 2026-11-17): a designed backlog item for a `refine-ticket` skill (Definition of Ready, interview with `grilling`, vertical slices, adversarial review with evidence from two reviewers in round 1 and then the more useful one, then the user's approval before `ready`), compared against Matt Pocock's skills and pstack. Also adds the `grilling` skill, copied from Matt Pocock's skills (MIT, pinned to upstream commit 7739eae).
  - PR #9 (open, branch `ready-003`): marks `refine-ticket` ready as ticket 003, at the user's request (2026-11-17).
  - Designed, not ready: delete expired sessions, and the server container image. The user moved both back from `ready` before #7 merged.
  - **Next:** after #9 merges, an agent builds 003 with the `next-ticket` skill (`scripts/ticket.sh claim next`). The user marks the other tickets `ready` when satisfied with them.

- **Purpose:** a learning project, for exploring technology the user hasn't worked with before: phone apps, GitOps, OpenTelemetry, and more. Build things the real way, and explain new technology as it's introduced.

- **Repo:** `/home/groot/Share/dev/git/feisty`.
  - The project was renamed **test01**, but the directory keeps its old name on purpose.
  - Feature branches are named after their ticket, `NNN-<slug>`. The number is given when the ticket is marked `ready` (see `docs/backlog/README.md`).
  - Remote `origin` is `git@github-test01:JD-cookie/Test01.git` on GitHub, reached over SSH through a write-enabled **deploy key** for this repo only (`~/.ssh/github_test01`, with an `~/.ssh/config` alias `github-test01`). The repo is **public**.
  - The `gh` CLI (2.46) is logged in as `JD-cookie` with a fine-grained token limited to Test01. It can read the repo and create PRs, but not Actions secrets, variables, or admin settings. Its config is in `~/.config/gh/hosts.yml`. `gh` resolves the `github-test01` alias without needing `-R`.
- **Stack:**
  - App: Expo SDK 58 with React Native, TypeScript, and Expo Router, in `app/`.
  - Backend: Node 24 with Fastify and `node:sqlite`, in `server/`. Optional Valkey (`VALKEY_URL`, client `iovalkey`) for rate-limit counters.
  - Spec: `docs/`.
  - Backlog: `docs/backlog/README.md` lists work not built yet, with design docs alongside it.
- **Done:**
  - Feature 001, accounts: sign up, log in, stay logged in, log out. Spec in `docs/features/001-accounts.md`.
  - Feature 002, rate limiting of login and signup: limits per client (an IPv4 address or an IPv6 /64) and per client+email for failed logins. Counters are in Valkey when `VALKEY_URL` is set, otherwise in memory, and the limiter fails open. `TRUST_PROXY` is supported. Spec in `docs/features/002-rate-limiting.md`. Merged in PR #1, released as server 0.2.0.
  - Environment support: dev, staging, and production app variants, the `/api/v1` prefix, the `X-App-Version` header with a `MIN_APP_VERSION` check that shows the "Update required" screen, and `/api/v1/meta`. Spec in `docs/devops.md`.
  - Device setup guides: `docs/dev-setup-phone.md` and `docs/dev-setup-android-studio-ubuntu.md`.

## Verified

- Server: typecheck is clean. `npm test` runs 23 tests, and all pass. The 3 Valkey tests are skipped unless `VALKEY_URL` is set. With Valkey 9 running in podman, all 26 pass. CI runs them with a Valkey service.
- Rate limiting was checked live against Valkey: the 6th failed login got `429` with `Retry-After: 900`, and the keys had the expected TTLs. With Valkey stopped, the server started after its 5 s wait, logins worked in about 40 ms, and an error was logged for each request.
- App: lint and typecheck are clean, and expo-doctor passes 20 of 20 checks. The Android bundle exports.
- Each variant's config resolves correctly with `expo config`. Misconfigured builds fail with clear errors.
- Two servers ran side by side over the LAN IP, each with its own database. The version check returned 426 for an app that was too old.
- **First real run (2026-11-12):** the user ran the dev app in Expo Go on their phone and tested creating an account and logging in. Both worked. The dev server and Expo/Metro were shut down afterwards.

## Not yet verified

- Only create account and log in were tested on the phone. Staying logged in after an app restart, and logging out, haven't been confirmed on a device yet. The emulator hasn't been tried.
- No EAS build has been done, and no APK has been installed. On the first staging APK, check that the footer shows `http://10.0.0.78:4000`. Expo's docs are unclear on whether the `env` values in `eas.json` versus EAS dashboard variables affect the server address.
- The steps in the setup guides haven't been tested by hand.

## Open items and next steps

- **Merged PRs** (all squash-merged with the PR title):
  - 2026-11-13: #2 (husky), #3 (CI, Conventional Commits, release-please), #1 (rate limiting), #4 (release-please's release PR), #5 (AGENTS.md), #6 (the PR title check uses the base branch's commitlint rules, which covers the Qodo finding on #3 that was left open).
  - 2026-11-16: #7 (the backlog as the ticket system, `scripts/ticket.sh`, the `next-ticket` skill), after Qodo reviewed every push and each finding was fixed.
  - 2026-11-17: #8 (the `grilling` skill and the `refine-ticket` design), with both Qodo findings fixed.
- **Open PRs:** #9, ticket 003 marked `ready`.
- **Release process:** works end to end.
  - Merging #1 made the App open #4, which bumped the server to 0.2.0 (`package.json`, the lockfile, the manifest, and `server/CHANGELOG.md`) and left the app at 0.1.0. CI ran on it.
  - Merging #4 created the tag `server-v0.2.0` and the GitHub Release "server: v0.2.0".
  - Qodo is set not to review bot PRs, so release PRs get no Qodo review.
  - `237065b` (both parts at 0.1.0) is tagged `server-v0.1.0` and `app-v0.1.0` (annotated, 2026-11-17), so the 0.2.0 compare link works.
  - App Client ID `Iv23liyEkVVtGp2Shoka` (not secret).
- **Next (user):** on the phone, confirm that staying logged in (kill and reopen the app) and logging out both work.
- Everything else (what the app does beyond accounts, password reset, production hosting, and so on) is in `docs/backlog/README.md`. Pick from there.

## Working agreements and gotchas

**The project rules, setup, and verify commands are in [`AGENTS.md`](AGENTS.md)** (`CLAUDE.md` imports it): Count Before You Check, No Shared State in Process Memory, Every Feature Ships With Its Doc, Release Tooling Owns Versions and Changelogs, and Least-Privilege Workflows. Don't repeat them here. Below are only the notes about this machine and how the user likes to work.

- New requests and known gaps go in `docs/backlog/README.md`, not in this file.
- Don't offer to commit every small change: the user batches commits. PR work (branch, commit, push, PR) is fine when the user asked for the work.
- After creating or updating a PR, check it about 10 minutes later for reviews, comments, and checks, then 30 minutes after that if nothing changed. Qodo doesn't review bot PRs, such as release-please's.
- `gh` 2.46: `gh pr edit` fails (a Projects classic error). Update PRs with `gh api -X PATCH repos/JD-cookie/Test01/pulls/N`.
- `app/.npmrc` sets `legacy-peer-deps=true` to get past a `react-dom` 19.3.1 / `react` 19.3.0 peer conflict in SDK 58.
- **Containers: podman, not Docker** (podman 5.7 and buildah are installed). The user has done manual Linux server deploys and some GitHub Actions CI, but has little experience with CD, GitOps, or Kubernetes. Explain those from the basics.
- The dev server has no GUI, Java, Android SDK, Docker, or Kubernetes tools. Builds go through EAS in the cloud. Devices connect over the LAN at `10.0.0.78` or through an SSH tunnel with `adb reverse`.
