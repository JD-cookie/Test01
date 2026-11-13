# Project status

Last updated 2026-11-13. This is a handoff note between working sessions. The system spec is in `docs/`; this file tracks where the work stands.

## Where things are

- **Qodo hackathon** ("Build a Software Factory in 30 Days", 2026-11-02 to 2026-12-02): the user is entering with this project. There are 23 weekday challenges, and missed ones can be caught up before the final cutoff (midnight Pacific at the end of Dec 2). Each challenge gets a focused branch and PR with a Qodo review. The user posts each submission in that challenge's Discussion. Rules: https://hackathon.qodo.ai/rules/. Submission template: https://github.com/orgs/qodo-hackathon/discussions/1. Progress so far: Day 1 (rate limiting, feature 002) merged in PR #1 (https://github.com/JD-cookie/Test01/pull/1). Day 2 (write AGENTS.md with 3–5 rules, have Qodo import them as Review Standards, and nominate one rule in the Day 2 Discussion) merged in PR #5 (2026-11-13): https://github.com/JD-cookie/Test01/blob/main/AGENTS.md. Left for the user: check that Qodo's Review Standards have the five rules (if not, use Import rules and skills, and activate them), and post the nomination in the Day 2 Discussion. Day 3 (connect the backlog to the agent, and work tickets one per branch and PR): the user chose to keep the backlog in the repo rather than an external tracker. On branch `backlog-tickets`:
  - the backlog is now the ticket system, with a `ready` status, a number assigned when a ticket is marked ready, and claims made by creating the ticket's branch
  - `scripts/ticket.sh`, the `next-ticket` skill, and the tickets 003 (delete expired sessions) and 004 (server container image)

  After it merges, work 003 and then 004 with the skill. The suggested nominee is "Count Before You Check", from Qodo's Day 1 finding. PR #2 (husky pre-commit checks) and PR #3 (CI, Conventional Commits, release-please) are merged. Still needed for Day 1 (https://github.com/orgs/qodo-hackathon/discussions/2): the user's intro comment and update in the Discussion.

- **Purpose:** a learning project, for exploring technology the user hasn't worked with before: phone apps, GitOps, OpenTelemetry, and more. Build things the real way, and explain new technology as it's introduced.

- **Repo:** `/home/groot/Share/dev/git/feisty`. The project was renamed **test01**, but the directory keeps its old name on purpose. Feature branches are named after their ticket, `NNN-<slug>`. The number is given when the user marks the ticket `ready` (see `docs/backlog/README.md`). Remote `origin` is `git@github-test01:JD-cookie/Test01.git` on GitHub. It's reached over SSH through a write-enabled **deploy key** for this repo only (`~/.ssh/github_test01`, with an `~/.ssh/config` alias `github-test01`). `main` has been pushed. The repo is **public**. For the GitHub API, the `gh` CLI (2.46) is logged in as `JD-cookie` with a fine-grained token limited to Test01 (it can read the repo and create PRs, but not Actions secrets, variables, or admin settings). Its config is in `~/.config/gh/hosts.yml`. `gh` resolves the `github-test01` alias without needing `-R`.
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

0. Merged 2026-11-13, all squash-merged with the PR title: #2 (husky), #3 (CI, Conventional Commits, release-please), #1 (rate limiting), #4 (release-please's release PR), #5 (AGENTS.md), and #6 (the PR title check uses the base branch's commitlint rules, which covers the Qodo finding on #3 that was left open). No PRs are open.
1. Release process: works end to end. Merging #1 made the App open #4, which bumped the server to 0.2.0 (`package.json`, the lockfile, the manifest, and `server/CHANGELOG.md`) and left the app at 0.1.0. CI ran on it. Merging #4 created the tag `server-v0.2.0` and the GitHub Release "server: v0.2.0". Qodo is set not to review bot PRs, so release PRs get no Qodo review. The 0.2.0 compare link 404s because there's no `server-v0.1.0` tag. Claude offered to tag `237065b` as `server-v0.1.0`/`app-v0.1.0`; no answer yet. App Client ID `Iv23liyEkVVtGp2Shoka` (not secret).
2. On the phone, confirm that staying logged in (kill and reopen the app) and logging out both work.
3. Everything else (deciding what the app does beyond accounts, password reset, production hosting, and so on) is in `docs/backlog/README.md`. Pick from there.

## Working agreements and gotchas

**The project rules, setup, and verify commands are in [`AGENTS.md`](AGENTS.md)** (`CLAUDE.md` imports it): Count Before You Check, No Shared State in Process Memory, Every Feature Ships With Its Doc, Release Tooling Owns Versions and Changelogs, and Least-Privilege Workflows. Don't repeat them here. Below are only the notes about this machine and how the user likes to work.

- New requests and known gaps go in `docs/backlog/README.md`, not in this file.
- Don't offer to commit every small change: the user batches commits. PR work (branch, commit, push, PR) is fine when the user asked for the work.
- After creating or updating a PR, check it about 10 minutes later for reviews, comments, and checks, then 30 minutes after that if nothing changed. Qodo doesn't review bot PRs, such as release-please's.
- `gh` 2.46: `gh pr edit` fails (a Projects classic error). Update PRs with `gh api -X PATCH repos/JD-cookie/Test01/pulls/N`.
- `app/.npmrc` sets `legacy-peer-deps=true` to get past a `react-dom` 19.3.1 / `react` 19.3.0 peer conflict in SDK 58.
- **Containers: podman, not Docker** (podman 5.7 and buildah are installed). The user has done manual Linux server deploys and some GitHub Actions CI, but has little experience with CD, GitOps, or Kubernetes. Explain those from the basics.
- The dev server has no GUI, Java, Android SDK, Docker, or Kubernetes tools. Builds go through EAS in the cloud. Devices connect over the LAN at `10.0.0.78` or through an SSH tunnel with `adb reverse`.
