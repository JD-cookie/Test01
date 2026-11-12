# DevOps: environments, builds, versions, and deploys

This doc explains how Test01 is configured, tested, built, and released in each environment, and how app and server versions stay compatible. Any rebuild of the system should provide the same environments, settings, and compatibility rules. The commands are specific to the current technology: Expo and EAS for the app, Node for the server.

## Environments

| | Automated tests | Development | Staging | Production |
|---|---|---|---|---|
| **Purpose** | Server API tests on every change | Day-to-day work | Try a release candidate before it goes live | Real users |
| **App** | none | Expo Go, live reload | `staging` APK | `production` APK |
| **App name / ID** | — | Test01 (Dev) / `com.test01.app.dev` | Test01 (Staging) / `com.test01.app.staging` | Test01 / `com.test01.app` |
| **Server** | started inside the test process | `npm run dev` on the dev machine, port 3000 | a separate server process on port 4000 (dev machine for now) | an always-on host, not chosen yet |
| **Database** | new in-memory SQLite for every test | `server/data/test01.db` | its own file, e.g. `server/data/staging.db` | its own file on the production host, backed up |
| **Transport** | in-process | HTTP on the LAN | HTTP on the LAN | **HTTPS only** (the production build refuses anything else) |

Each app variant has its own app ID, so the Dev, Staging, and production apps can be installed on the same phone side by side. Each keeps its own login. Each server has its own database, so the environments never share data.

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
| App version | `version` in `app/app.json`, and keep `app/package.json` matching | Every APK you hand out |
| Server version | `version` in `server/package.json` | Every server deploy |
| `MIN_APP_VERSION` | server environment | Only when old apps must stop working, e.g. after a security fix or the removal of an old API version |
| API version | `API_VERSION` in `server/src/app.ts`, and the `/api/v1` prefix in `app/src/api.ts` | Only for breaking API changes |

## Database changes

- The schema is changed by an ordered list of SQL migrations in `server/src/db.ts`. The database records how many have run in `PRAGMA user_version`. On startup, the server runs any missing migrations, each inside a transaction.
- Never edit a migration that has shipped. Add a new one instead.
- Make migrations compatible with the app versions still in use: add columns and tables rather than renaming or dropping them while older code still depends on them.
- Before a production deploy, test the new server against a **copy of the production database** in staging: copy the file and point staging's `DB_PATH` at the copy.

## Workflows

### Run the tests

```bash
cd server && npm test && npm run typecheck   # API tests, each on a fresh in-memory database
cd app && npm run lint && npm run typecheck
```

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
1. **Server first.** Bump the server version, test in staging against a copy of production data, back up the production database, then deploy and restart. Check `GET /api/v1/meta`.
2. **Then the app.** Bump the app version. Set the production `API_URL`, either in the `production` profile's `env` in `app/eas.json` or as an EAS environment variable, then run:
   ```bash
   cd app && npx eas-cli@latest build -p android --profile production
   ```
   Install the APK on the phone. It updates the existing "Test01" app in place.
3. **Only if older apps must stop working,** raise `MIN_APP_VERSION` on the server.

Deploy the server before the app because a new app may rely on new endpoints, while older apps keep working with a newer server, per the compatibility rules above.

## Known gaps and caveats

- **Not tested on a device yet.** The variant config, cleartext setting, and builds have been checked with `expo config` and a local bundle export, but no EAS build has run and no APK has been installed yet.
- **Build environment variables.** Expo's docs don't spell out how the `env` block in `eas.json` interacts with environment variables set on the EAS dashboard. Check the footer of the first staging build to confirm it uses the expected server.
- **The staging server address is this machine's LAN IP** (`10.0.0.78`). If that IP changes, update `app/eas.json` and rebuild.
- **iOS:** the variants already have bundle IDs, but there's no iOS build profile yet. Installing on an iPhone needs an Apple Developer account.
- **Over-the-air updates** (EAS Update) aren't set up. Every app change needs a new APK.
- **`app/.npmrc` sets `legacy-peer-deps=true`.** It works around a peer-dependency conflict in Expo SDK 58 between `react-dom` 19.3.1 and the pinned `react` 19.3.0. Remove it once the SDK moves to a newer `react`.
