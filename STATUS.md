# Project status

Last updated 2026-11-12. This is a handoff note between working sessions. The system spec is in `docs/`; this file tracks where the work stands.

## Where things are

- **Purpose:** a learning project, for exploring technology the user hasn't worked with before: phone apps, GitOps, OpenTelemetry, and more. Build things the real way, and explain new technology as it's introduced.

- **Repo:** `/home/groot/Share/dev/git/feisty`. The project was renamed **test01**, but the directory keeps its old name on purpose. Branch `main`. First commit is `d5f3a9a` ("Create account & login works").
- **Stack:**
  - App: Expo SDK 58 with React Native, TypeScript, and Expo Router, in `app/`.
  - Backend: Node 24 with Fastify and `node:sqlite`, in `server/`.
  - Spec: `docs/`.
  - Backlog: `docs/backlog/README.md` lists work not built yet, with design docs alongside it.
- **Done:**
  - Feature 001, accounts: sign up, log in, stay logged in, log out. Spec in `docs/features/001-accounts.md`.
  - Environment support: dev, staging, and production app variants, the `/api/v1` prefix, the `X-App-Version` header with a `MIN_APP_VERSION` check that shows the "Update required" screen, and `/api/v1/meta`. Spec in `docs/devops.md`.
  - Device setup guides: `docs/dev-setup-phone.md` and `docs/dev-setup-android-studio-ubuntu.md`.

## Verified

- Server: 10 tests pass (`npm test`), and typecheck is clean.
- App: lint and typecheck are clean, and expo-doctor passes 20 of 20 checks. The Android bundle exports.
- Each variant's config resolves correctly with `expo config`. Misconfigured builds fail with clear errors.
- Two servers ran side by side over the LAN IP, each with its own database. The version check returned 426 for an app that was too old.
- **First real run (2026-11-12):** the user ran the dev app in Expo Go on their phone and tested creating an account and logging in. Both worked. The dev server and Expo/Metro were shut down afterwards.

## Not yet verified

- Only create account and log in were tested on the phone. Staying logged in after an app restart, and logging out, haven't been confirmed on a device yet. The emulator hasn't been tried.
- No EAS build has been done, and no APK has been installed. On the first staging APK, check that the footer shows `http://10.0.0.78:4000`. Expo's docs are unclear on whether the `env` values in `eas.json` versus EAS dashboard variables affect the server address.
- The steps in the setup guides haven't been tested by hand.

## Open items and next steps

0. PRs: #2 (husky) merged on 2026-11-13 as `135e219`. Its squash commit used the PR title, so the merge settings work. #3 (release process) was rebased onto main. #1 (rate limiting) is open. Merge #3 next, then rebase #1.
1. On the phone, confirm that staying logged in (kill and reopen the app) and logging out both work.
2. Release App setup: the user reports it's configured (2026-11-12). Verified through the API: a `release` environment exists, limited to the branch `main`. Claude's token can't see the secret, the repository variable, the App installation, the merge settings, or the workflow permissions (403, as intended). The real test is the first push to `main` after PR #3 merges: the Release Please run should get a token and, once a `feat`/`fix` commit is on `main`, open a `chore(release): …` PR. App Client ID `Iv23liyEkVVtGp2Shoka` (not secret). Setup steps: `docs/devops.md` → Versioning and releases.
3. Everything else (deciding what the app does beyond accounts, rate limiting, password reset, production hosting, and so on) is in `docs/backlog/README.md`. Pick from there.

## Working agreements and gotchas

- **New requests and known gaps go in `docs/backlog/README.md`**, not in this file. A design doc, if there is one, sits next to it as `docs/backlog/<slug>.md`. When it's built, it moves to `docs/features/NNN-<slug>.md`. The steps are in the backlog README.
- **Commit messages / PR titles: Conventional Commits** (`feat(server): …`, `fix(app): …`, `docs: …`), enforced by a `commit-msg` hook (commitlint) and by CI's `pr-title` job. PRs get squash-merged with the PR title as the commit. Versions and `server/CHANGELOG.md` and `app/CHANGELOG.md` come from release-please. Never bump versions or edit changelogs by hand. See `docs/devops.md` → Versioning and releases.
- **CI** (`.github/workflows/ci.yml`): server check (with a Valkey service), app check, and PR title. Workflow rules: read-only token by default, actions pinned to full SHAs, no `pull_request_target`. Run actionlint via podman before pushing workflow changes.
- **Git hooks:** husky (repo-root `package.json`) runs a `pre-commit` hook that runs `npm run check` in `server/` and/or `app/`, for whichever has staged changes. Run `npm install` at the root after cloning to turn it on. Don't bypass it with `--no-verify` unless the user asks.
- **Every feature gets a doc** in `docs/features/NNN-*.md`, written in the same change that builds it. It must hold enough detail to reimplement the system from the docs alone. See `docs/README.md` for what each doc should contain. Operational changes go in `docs/devops.md`.
- Use `npx expo install <pkg>` for app packages. `app/.npmrc` sets `legacy-peer-deps=true` to get past a `react-dom` 19.3.1 / `react` 19.3.0 peer conflict in SDK 58.
- `app/AGENTS.md`, from the Expo template, says Expo changes often: check the versioned docs at docs.expo.dev rather than relying on memory.
- **Containers: podman, not Docker** (podman 5.7 and buildah are installed). The user has done manual Linux server deploys and some GitHub Actions CI, but has little experience with CD, GitOps, or Kubernetes. Explain those from the basics.
- **Data stores:** SQLite is for development and tests only. Staging and production will use a database server, not chosen yet, plus Valkey for shared state. Keep SQL portable, and never keep shared state in process memory. See `docs/devops.md` → Environments.
- The dev server has no GUI, Java, Android SDK, Docker, or Kubernetes tools. Builds go through EAS in the cloud. Devices connect over the LAN at `10.0.0.78` or through an SSH tunnel with `adb reverse`.
