# DevOps: environments, builds, versions, and deploys

This doc explains how Test01 is configured, tested, built, and released in each environment, and how app and server versions stay compatible. Any rebuild of the system should provide the same environments, settings, and compatibility rules. The commands are specific to the current technology: Expo and EAS for the app, Node for the server.

## Environments

| | Automated tests | Development | Staging | Production |
|---|---|---|---|---|
| **Purpose** | Server API tests on every change | Day-to-day work | Try a release candidate before it goes live | Real users |
| **App** | none | Expo Go, live reload | `staging` APK | `production` APK |
| **App name / ID** | — | Test01 (Dev) / `com.test01.app.dev` | Test01 (Staging) / `com.test01.app.staging` | Test01 / `com.test01.app` |
| **Server** | started inside the test process | `npm run dev` on the dev machine, port 3000 | a separate server process on port 4000 (dev machine for now) | an always-on host, not chosen yet |
| **Database** | new in-memory SQLite for every test | SQLite, `server/data/test01.db` | **planned:** a database server, not chosen yet. For now, its own SQLite file, e.g. `server/data/staging.db` | **planned:** a database server, not chosen yet, backed up |
| **Shared state** (rate limits, caches) | none | none: one process | **planned:** Valkey | **planned:** Valkey |
| **Transport** | in-process | HTTP on the LAN | HTTP on the LAN | **HTTPS only** (the production build refuses anything else) |

Each app variant has its own app ID, so the Dev, Staging, and production apps can be installed on the same phone side by side. Each keeps its own login. Each server has its own database, so the environments never share data.

**Containers.** Use podman and buildah, not Docker. Container files are named `Containerfile`. Kubernetes runs any OCI image, so podman-built images need no changes.

**Data store plan.** SQLite is for development and tests only. Staging and production will use a client-server relational database, so that several server instances can run against the same data. The database hasn't been chosen yet. Shared state between instances, such as rate-limit counters, will go in Valkey, the open-source fork of Redis, and never in process memory. Until this is built, the server supports only one instance per database. It doesn't need sticky load balancing, because sessions live in the database. The work is tracked in [backlog/README.md](backlog/README.md).

## Configuration reference

### App (applied when the app is bundled or built, in `app/app.config.ts`)

| Variable | Values | Effect |
|---|---|---|
| `APP_VARIANT` | `development` (default), `staging`, `production` | Sets the app name suffix, the app ID, the URL scheme (`test01-dev`, `test01-staging`, `test01`), and whether plain HTTP is allowed. Any other value fails the build. |
| `API_URL` | e.g. `http://10.0.0.78:4000`, `https://api.example.com` | The backend address, without the `/api/v1` part. Required for staging and production builds, which fail without it. Production builds also fail unless it starts with `https://`. In development it's optional: without it, the app uses port 3000 on the machine that serves the JavaScript bundle. |

How it works:
- `app.json` holds the shared settings.
- `app.config.ts` adds the per-variant settings on top and stores `variant` and `apiUrl` in the config's `extra` field. The app reads them at runtime through `expo-constants` (`app/src/api.ts`).
- Android blocks plain-HTTP requests in release builds unless the build allows them. `app.config.ts` allows them through the `expo-build-properties` `usesCleartextTraffic` setting, which is on for development and staging and off for production.

The app version comes from `version` in `app/app.json`. Every non-production screen shows a small footer with the variant, the app version, and the server address, e.g. `staging · v0.1.0 · http://10.0.0.78:4000`, so you can always tell which build is talking to which server. Production builds don't show it.

### Server (environment variables, optionally from `server/.env`)

| Variable | Default | Effect |
|---|---|---|
| `PORT` | `3000` | Port to listen on |
| `HOST` | `0.0.0.0` | Interface to listen on. `0.0.0.0` lets phones on the LAN connect. |
| `DB_PATH` | `server/data/test01.db` | SQLite database file. It's created, and its schema updated, on startup. |
| `MIN_APP_VERSION` | `0.0.0` | Apps reporting an older version get `426 UPGRADE_REQUIRED` (see below). |

`npm run dev` and `npm start` load `server/.env` if it exists (see `server/.env.example`). Variables set in the shell take precedence, so one checkout can run several servers.

## API versioning and app compatibility

Installed apps stay on whatever version they were installed at until someone updates them. So the server must keep serving older apps. These rules make that work:

1. **Versioned paths.** Every endpoint is under `/api/v<N>/`; it's currently `/api/v1`. Within a version, changes must be **backward compatible**: new endpoints, new optional request fields, and new response fields are fine. Removing or renaming fields, changing their meaning, or adding required inputs is not. A breaking change needs `/api/v2`, and the server keeps serving `/api/v1` until no supported app uses it.
2. **The app reports its version.** Every request from the app carries `X-App-Version: <app version>`, e.g. `0.1.0`.
3. **Minimum app version.** If `X-App-Version` is lower than `MIN_APP_VERSION`, any `/api/v1/*` request except `/api/v1/meta` gets:
   ```json
   426 { "error": { "code": "UPGRADE_REQUIRED", "message": "A newer version of the app is required. Please install the latest version." } }
   ```
   - Versions are compared as dotted numbers, part by part: `1.10.0` > `1.9.0`, and missing parts count as 0.
   - Requests without the header aren't checked. That covers curl, tests, and monitoring.
   - `/api/health` and `/api/v1/meta` are never blocked.
4. **What the app does on a 426.** On any `UPGRADE_REQUIRED` response, the app replaces every screen with **Update required**: the heading "Update required", the subtitle "You have version <x.y.z>.", and the text "This version of the app is no longer supported. Please install the latest version, then open the app again. You will not need to log in again." The saved session is kept, so after updating, the user is still logged in.
5. **Unknown paths.** These return `404 { "error": { "code": "NOT_FOUND", "message": "Not found." } }`.

### Shared endpoints

- `GET /api/health` → `200 {"status":"ok"}`. Has no version prefix and is never blocked; it's for uptime checks.
- `GET /api/v1/meta` → `200 {"apiVersion":1,"serverVersion":"0.1.0","minAppVersion":"0.0.0"}`. `serverVersion` is the `version` from `server/package.json`. Use it to check which server version an environment is running.

### Versions to bump

| What | Where | When |
|---|---|---|
| App version | `version` in `app/app.json` and `app/package.json` | Set by the release PR (see [Versioning and releases](#versioning-and-releases)). Don't edit it by hand. |
| Android build number (`versionCode`) | EAS servers (`appVersionSource: remote` in `app/eas.json`) | Raised by EAS on every staging or production build (`autoIncrement`) |
| Server version | `version` in `server/package.json` | Set by the release PR. Don't edit it by hand. |
| `MIN_APP_VERSION` | server environment | Only when old apps must stop working, e.g. after a security fix or the removal of an old API version |
| API version | `API_VERSION` in `server/src/app.ts`, and the `/api/v1` prefix in `app/src/api.ts` | Only for breaking API changes |

## Database changes

- The schema is changed by an ordered list of SQL migrations in `server/src/db.ts`. The database records how many have run in `PRAGMA user_version`. On startup, the server runs any missing migrations, each inside a transaction.
- Never edit a migration that has shipped. Add a new one instead.
- Keep schema and queries portable (plain types, no SQLite-only features), because staging and production will move to a different database. See the data store plan under [Environments](#environments).
- Make migrations compatible with the app versions still in use: add columns and tables rather than renaming or dropping them while older code still depends on them.
- Before a production deploy, test the new server against a **copy of the production database** in staging: copy the file and point staging's `DB_PATH` at the copy.

## Versioning and releases

The **server** and the **app** each have their own version, in [SemVer](https://semver.org) form `MAJOR.MINOR.PATCH`, and their own changelog: `server/CHANGELOG.md` and `app/CHANGELOG.md`. Nobody edits versions or changelogs by hand. They come from the commit messages on `main`.

### What counts as a patch, minor, or major change

| Bump | Server | App |
|---|---|---|
| **Major** | A breaking API change: a new `/api/vN`, or stopping support for an API version or for old apps | A deliberate big break, e.g. a redesign that drops a feature. Rare. |
| **Minor** | New endpoints, new optional fields, new behavior old apps don't notice | New screens or features |
| **Patch** | Bug fixes, security fixes that change no behavior a client relies on, performance | Bug fixes and small visual fixes |
| **None** | Docs, tests, CI, refactoring, tooling | Same |

**Before 1.0.0** (both components are 0.x now), a breaking change bumps the *minor* number, e.g. 0.3.0 → 0.4.0, and features also bump the minor number. Declare 1.0.0 by hand (see "Overriding the version" below) once the API is meant to be stable. Raising `MIN_APP_VERSION` isn't a version bump: it's an operational decision. Write it up in the release notes of the server release that needs it.

### Commit messages: Conventional Commits

Every commit on `main` follows [Conventional Commits](https://www.conventionalcommits.org): `type(scope): summary`.

| Type | Meaning | Version bump |
|---|---|---|
| `feat` | A new feature | minor |
| `fix` | A bug fix | patch |
| `perf` | A performance improvement | patch |
| `deps` | A dependency update that affects the shipped code | patch |
| `revert` | Reverts an earlier commit | patch |
| `feat!`, `fix!`, …, or a `BREAKING CHANGE:` footer | A breaking change. The footer explains what users must do. | major (minor before 1.0) |
| `docs`, `test`, `refactor`, `build`, `ci`, `chore`, `style` | No change to shipped behavior | none |

- **Scope** (optional): `app`, `server`, `docs`, `ci`, `repo`, `deps`, or `release`. It's for readers. The component a change belongs to comes from the **paths it touches**: `server/…` goes into the server's next release, and `app/…` into the app's. A commit touching both goes into both.
- **The summary becomes a changelog line,** so write it for someone reading release notes: "rate limiting of login and signup", not "address review".
- Examples: `feat(server): rate limiting of login and signup`, `fix(app): keep the form contents after a 429`, `feat(server)!: remove /api/v1`.

How it's enforced:
- **Locally:** the `commit-msg` hook (`.husky/commit-msg`) runs commitlint (`commitlint.config.mjs`) and rejects anything else.
- **PRs are squash-merged,** so each PR becomes one commit on `main` and **the PR title is its message**. Commits inside a PR branch only need to pass the hook. The title is what ends up in the changelog, and CI checks it (`pr-title` job).
- **Repo settings (once):** Settings → General → Pull Requests: allow **squash merging** only, and set its default commit message to **"Pull request title"**, or "Pull request title and description".

### Releasing: release-please

[release-please](https://github.com/googleapis/release-please) runs on every push to `main` (`.github/workflows/release-please.yml`). It works out the next version for each component from the commits since that component's last release, then opens or updates a single **release PR** titled `chore(release): release main`. That PR:
- bumps `server/package.json` (and its lockfile), and `app/package.json`, its lockfile, and `app/app.json` (`expo.version`)
- adds the new entries to each `CHANGELOG.md`
- updates `.release-please-manifest.json`, which records each component's current version

Nothing is released until you **merge the release PR**. Merging it creates the git tags (`server-v0.2.0`, `app-v0.2.0`) and a GitHub release for each component. Then deploy or build from those tags. See [Production: release](#production-release). Until then, the release PR keeps updating as more changes merge, so releasing is a decision rather than a side effect of merging.

Files: `release-please-config.json` (components, changelog sections, PR title, and `bootstrap-sha`, the commit before which history is ignored) and `.release-please-manifest.json` (current versions).

**Overriding the version:** add a commit with a `Release-As: 1.0.0` footer, e.g. `chore(server): release 1.0.0` with that footer, and release-please will propose exactly that version.

**Authentication: a GitHub App, not `GITHUB_TOKEN`.** The repo setting "Allow GitHub Actions to create and approve pull requests" stays **off**. That setting lets any workflow approve its own PRs, which can get around required reviews. Instead, release-please uses a token from a small GitHub App that is installed only on this repo. The token is created fresh on each run, expires within an hour, and is narrowed in the workflow to contents, pull-requests, and issues write. A side benefit: PRs opened with `GITHUB_TOKEN` don't trigger other workflows, so CI wouldn't run on the release PR. With an App token it does. Setup, once:
1. GitHub → Settings → Developer settings → **GitHub Apps → New GitHub App**.
   - Name: e.g. `test01-release-please`. Homepage URL: the repo URL.
   - **Webhook:** untick "Active".
   - **Repository permissions:** Contents: Read and write. Pull requests: Read and write. Issues: Read and write, which release-please uses for its labels. Leave everything else at No access.
   - **Where can this GitHub App be installed?** Only on this account.
2. Create the App. On its page, note the **Client ID**. Under "Private keys", **generate a private key**, which downloads a `.pem` file.
3. **Install App** → only select repositories → `Test01`.
4. In the Test01 repo → Settings → Secrets and variables → Actions:
   - **Variables** tab: `RELEASE_APP_CLIENT_ID` = the Client ID. It's not secret.
   - **Secrets** tab: `RELEASE_APP_PRIVATE_KEY` = the whole contents of the `.pem` file. Then delete the downloaded file.

Until `RELEASE_APP_CLIENT_ID` is set, the release workflow's job is skipped rather than failing.

## CI

`.github/workflows/ci.yml` runs on every PR and every push to `main`:

| Job | What it does |
|---|---|
| `server` | `npm ci` and `npm run check` (typecheck and tests) in `server/`, with a Valkey 9 service container and `VALKEY_URL` set, so the Valkey store tests run too |
| `app` | `npm ci` and `npm run check` (typegen, lint, typecheck) in `app/` |
| `pr-title` | PRs only: checks the PR title with the same commitlint rules as the commit hook |

Editing a PR's title or description reruns only `pr-title`. A newer push to the same PR cancels the run in progress.

Security conventions for every workflow in this repo:
- **Least privilege:** the workflow-level `permissions:` is read-only, `contents: read`, or none at all (`{}`). A job that needs more asks for it explicitly. The repo's default workflow permissions should also be read-only: Settings → Actions → General → Workflow permissions → "Read repository contents and packages permissions".
- **Pinned actions:** every action is referenced by its full commit SHA, with the version in a comment, e.g. `actions/checkout@3d3c42e5… # v7.0.1`. A tag like `@v7` can be moved to different code, and a SHA can't. To update one, look up the new release's commit SHA and change both.
- **Untrusted input:** never use `pull_request_target`, which runs fork PRs with secrets. Pass PR data such as titles into scripts through `env:`, never by pasting `${{ … }}` into a `run:` script, where a crafted title could inject commands.
- `actions/checkout` uses `persist-credentials: false`, so later steps can't reuse the token to push.

Check workflow changes with [actionlint](https://github.com/rhysd/actionlint) before pushing:

```bash
podman run --rm -v "$PWD:/repo:Z" -w /repo docker.io/rhysd/actionlint:latest -no-color
```

## Workflows

### Run the tests

```bash
npm run check                  # repo root: everything below
npm --prefix server run check  # typecheck + API tests, each on a fresh in-memory database
npm --prefix app run check     # typegen + lint + typecheck
```

The pre-commit hook runs these automatically for the parts you changed (see the README), and CI runs them on every PR.

### Development: the app on your phone with live reload

Device setup guides: [a real Android phone](dev-setup-phone.md), or [the Android emulator on Ubuntu](dev-setup-android-studio-ubuntu.md) connected to the remote dev server.

```bash
cd server && npm run dev            # terminal 1: dev server on port 3000
cd app && npx expo start            # terminal 2: scan the QR code with Expo Go
```

### Point the dev app at a different server or server version

1. Start the other server on its own port with its own database. For another version, check out that version in a separate folder first, e.g. with `git worktree add ../test01-v2 <branch>`. Then:
   ```bash
   cd server && PORT=4000 DB_PATH=data/staging.db npm start
   ```
2. Start the app pointed at it:
   ```bash
   cd app && API_URL=http://10.0.0.78:4000 npx expo start
   ```
   Or put `API_URL=...` in `app/.env.local`, which Expo loads on its own. Restart `expo start` after changing it.
3. Check the footer on the screen to confirm which server the app is using.

To try the update-required screen, start a server with `MIN_APP_VERSION=99.0.0`.

### Staging: build and install a staging APK

1. Start the staging server: `cd server && PORT=4000 DB_PATH=data/staging.db npm start`.
2. Build the APK. Its server address is `API_URL` in the `staging` profile of `app/eas.json`.
   ```bash
   cd app && npx eas-cli@latest build -p android --profile staging
   ```
3. Open the build link on the phone, download the APK, and install it. It installs as "Test01 (Staging)", alongside the other variants.

### Production: release

The production host hasn't been chosen yet. It needs to be:
- reachable from the internet over **HTTPS**, e.g. a small cloud server behind a reverse proxy, or a tunnel such as Cloudflare Tunnel or Tailscale Funnel;
- running the server as a service that restarts after a crash or a reboot;
- backed up: a copy of the database file, made while the server is stopped or with SQLite's `.backup`.

Once it exists:
1. **Release.** Merge the open release PR (see [Versioning and releases](#versioning-and-releases)). This tags `server-vX.Y.Z` and `app-vX.Y.Z` for whichever components changed.
2. **Server first.** Check out the `server-vX.Y.Z` tag, test it in staging against a copy of production data, back up the production database, then deploy and restart. Check that `GET /api/v1/meta` reports the new `serverVersion`.
3. **Then the app.** Build from the `app-vX.Y.Z` tag. The release PR already set the version, and EAS raises the Android build number. Set the production `API_URL`, either in the `production` profile's `env` in `app/eas.json` or as an EAS environment variable, then run:
   ```bash
   cd app && npx eas-cli@latest build -p android --profile production
   ```
   Install the APK on the phone. It updates the existing "Test01" app in place.
4. **Only if older apps must stop working,** raise `MIN_APP_VERSION` on the server.

Deploy the server before the app because a new app may rely on new endpoints, while older apps keep working with a newer server, per the compatibility rules above.

## Known gaps and caveats

- **No EAS build yet.** The dev app has run on a phone in Expo Go, but no EAS build has run and no APK has been installed. The variant config and cleartext setting have only been checked with `expo config` and a local bundle export. Remote versioning (`appVersionSource: remote`) starts the Android build number at 1 on the first build.
- **Build environment variables.** Expo's docs don't spell out how the `env` block in `eas.json` interacts with environment variables set on the EAS dashboard. Check the footer of the first staging build to confirm it uses the expected server.
- **The staging server address is this machine's LAN IP** (`10.0.0.78`). If that IP changes, update `app/eas.json` and rebuild.
- **iOS:** the variants already have bundle IDs, but there's no iOS build profile yet. Installing on an iPhone needs an Apple Developer account.
- **Over-the-air updates** (EAS Update) aren't set up. Every app change needs a new APK.
- **`app/.npmrc` sets `legacy-peer-deps=true`.** It works around a peer-dependency conflict in Expo SDK 58 between `react-dom` 19.3.1 and the pinned `react` 19.3.0. Remove it once the SDK moves to a newer `react`.
