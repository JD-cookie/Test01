# Project status

Last updated 2026-11-12. This is a handoff note between working sessions. The system spec is in `docs/`; this file tracks where the work stands.

## Where things are

- **Qodo hackathon** ("Build a Software Factory in 30 Days", 2026-11-02 to 2026-12-02): the user is entering with this project. There are 23 weekday challenges, and missed ones can be caught up before the final cutoff (midnight Pacific at the end of Dec 2). Each challenge gets a focused branch and PR with a Qodo review. The user posts each submission in that challenge's Discussion. Rules: https://hackathon.qodo.ai/rules/. Submission template: https://github.com/orgs/qodo-hackathon/discussions/1. Progress so far: the Day 1 capability (rate limiting, feature 002) is built on branch `002-rate-limiting` and has a PR open. Still needed for Day 1 (https://github.com/orgs/qodo-hackathon/discussions/2): Qodo connected to the repo and its review on the PR, plus the user's intro comment and update in the Discussion.

- **Purpose:** a learning project, for exploring technology the user hasn't worked with before: phone apps, GitOps, OpenTelemetry, and more. Build things the real way, and explain new technology as it's introduced.

- **Repo:** `/home/groot/Share/dev/git/feisty`. The project was renamed **test01**, but the directory keeps its old name on purpose. Feature branches are named after their feature doc, e.g. `002-rate-limiting` for `docs/features/002-rate-limiting.md`. The number is the next free feature number. Remote `origin` is `git@github-test01:JD-cookie/Test01.git` on GitHub. It's reached over SSH through a write-enabled **deploy key** for this repo only (`~/.ssh/github_test01`, with an `~/.ssh/config` alias `github-test01`). `main` has been pushed. The repo is **public**. For the GitHub API, the `gh` CLI (2.46) is logged in as `JD-cookie` with a fine-grained token limited to Test01 (issues, pull requests, contents read). Its config is in `~/.config/gh/hosts.yml`. `gh` resolves the `github-test01` alias without needing `-R`.
- **Stack:**
  - App: Expo SDK 58 with React Native, TypeScript, and Expo Router, in `app/`.
  - Backend: Node 24 with Fastify and `node:sqlite`, in `server/`. Optional Valkey (`VALKEY_URL`, client `iovalkey`) for rate-limit counters.
  - Spec: `docs/`.
  - Backlog: `docs/backlog/README.md` lists work not built yet, with design docs alongside it.
- **Done:**
  - Feature 001, accounts: sign up, log in, stay logged in, log out. Spec in `docs/features/001-accounts.md`.
  - Feature 002, rate limiting of login and signup: limits per client (an IPv4 address or an IPv6 /64) and per client+email for failed logins. Counters are in Valkey when `VALKEY_URL` is set, otherwise in memory, and the limiter fails open. `TRUST_PROXY` is supported. Spec in `docs/features/002-rate-limiting.md`. Not yet merged: PR from `002-rate-limiting`.
  - Environment support: dev, staging, and production app variants, the `/api/v1` prefix, the `X-App-Version` header with a `MIN_APP_VERSION` check that shows the "Update required" screen, and `/api/v1/meta`. Spec in `docs/devops.md`.
  - Device setup guides: `docs/dev-setup-phone.md` and `docs/dev-setup-android-studio-ubuntu.md`.

## Verified

- Server: typecheck is clean. `npm test` runs 22 tests, and all pass. The 3 Valkey tests are skipped unless `VALKEY_URL` is set. With Valkey 9 running in podman, all 25 pass.
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

1. Hackathon Day 1: the user connects Qodo to `JD-cookie/Test01` (if it isn't connected yet) and gets a Qodo review on the rate-limiting PR. Then address the review findings and merge. From now on, work goes on branches and into PRs, not straight to `main`.
2. On the phone, confirm that staying logged in (kill and reopen the app) and logging out both work.
3. Everything else (deciding what the app does beyond accounts, password reset, production hosting, and so on) is in `docs/backlog/README.md`. Pick from there.

## Working agreements and gotchas

- **New requests and known gaps go in `docs/backlog/README.md`**, not in this file. A design doc, if there is one, sits next to it as `docs/backlog/<slug>.md`. When it's built, it moves to `docs/features/NNN-<slug>.md`. The steps are in the backlog README.
- **Every feature gets a doc** in `docs/features/NNN-*.md`, written in the same change that builds it. It must hold enough detail to reimplement the system from the docs alone. See `docs/README.md` for what each doc should contain. Operational changes go in `docs/devops.md`.
- Use `npx expo install <pkg>` for app packages. `app/.npmrc` sets `legacy-peer-deps=true` to get past a `react-dom` 19.3.1 / `react` 19.3.0 peer conflict in SDK 58.
- `app/AGENTS.md`, from the Expo template, says Expo changes often: check the versioned docs at docs.expo.dev rather than relying on memory.
- **Containers: podman, not Docker** (podman 5.7 and buildah are installed). The user has done manual Linux server deploys and some GitHub Actions CI, but has little experience with CD, GitOps, or Kubernetes. Explain those from the basics.
- **Data stores:** SQLite is for development and tests only. Staging and production will use a database server, not chosen yet, plus Valkey for shared state. Keep SQL portable, and never keep shared state in process memory, except as a fallback for development and tests, as the rate limiter does. See `docs/devops.md` → Environments.
- The dev server has no GUI, Java, Android SDK, Docker, or Kubernetes tools. Builds go through EAS in the cloud. Devices connect over the LAN at `10.0.0.78` or through an SSH tunnel with `adb reverse`.
