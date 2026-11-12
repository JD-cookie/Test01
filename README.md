# Test01

A mobile app (Expo / React Native, for Android now and iPhone later) with its own backend (Node + Fastify + SQLite).

**Why this exists:** it's a learning project, for getting hands-on with technology I haven't worked with before: phone apps, GitOps, OpenTelemetry, and more. The app's features are mostly there to give that technology something real to do, so things are built the way a production system would build them, even where a shortcut would do for an app this size.

- `app/`: the mobile app
- `server/`: the backend API
- `docs/`: the system spec, with one document per feature. **Start at [docs/README.md](docs/README.md).**
- `package.json` and `.husky/` (repo root): git hooks only.

## Requirements

- Node 24+ on the development machine
- An Android phone on the **same Wi-Fi** as the development machine

## After cloning

```bash
npm install                  # repo root: installs husky and turns on the git hooks
npm --prefix server install
npm --prefix app install
```

## Run the backend

```bash
cd server
npm install
npm run dev        # http://0.0.0.0:3000, restarts when files change
npm test           # API tests
```

The data lives in `server/data/test01.db`. To start over with no accounts, delete that file.

## Run the app on your phone (development)

1. On the phone, install **Expo Go** from the Play Store.
2. Start the backend (see above). Then, in a second terminal:
   ```bash
   cd app
   npm install
   npx expo start
   ```
3. Open Expo Go and scan the QR code shown in the terminal. Saving a change to the code updates the app on your phone straight away.

The app finds the backend on its own, at port 3000 of the computer running `expo start`. To use a different server, see [docs/devops.md](docs/devops.md).

If the phone can't connect:
- Check that the phone and computer are on the same network.
- Allow ports 8081 and 3000 through the computer's firewall, e.g. `sudo ufw allow 8081,3000/tcp`.
- If it still fails, try `npx expo start --tunnel`.

## Install a standalone APK (no Play Store)

This builds a real `.apk` in Expo's cloud, so you don't need the Android SDK on this machine. It needs a free account at expo.dev.

```bash
cd app
npx eas-cli@latest login
npx eas-cli@latest build -p android --profile staging
```

When the build finishes, open the link it prints on your phone and download the `.apk`. Android will ask you to allow installs from your browser. Then install it, the same way you'd sideload Telegram. It installs as "Test01 (Staging)" and talks to the staging server on port 4000.

For the environments (dev, staging, production), the server settings, how to point the app at a different server, versioning, and releases, see **[docs/devops.md](docs/devops.md)**.

## Checks before committing

The checks run automatically. A [husky](https://typicode.github.io/husky/) `pre-commit` hook (`.husky/pre-commit`) runs `npm run check` for each part of the repo that has staged changes, and a failing check stops the commit:

| Staged changes in | Runs | Which is |
|---|---|---|
| `server/` | `npm --prefix server run check` | `typecheck`, then `test` |
| `app/` | `npm --prefix app run check` | `lint`, then `typecheck` |
| anything else (docs, root files) | nothing | |

To run every check by hand: `npm run check` from the repo root.

Notes:
- The checks run against **what's staged**, not your working tree. The hook exports the index to a temporary directory with `git checkout-index`, links in each part's installed `node_modules` (plus Expo's generated `app/expo-env.d.ts` and `app/.expo/types`), and runs `check` there. Unstaged edits can't make a check pass or fail, and your working tree and index aren't touched.
- Staged changes are detected with `git diff --cached --quiet -- server/` (and `app/`), so file names with unusual characters are handled.
- If a part's `node_modules` is missing, the hook stops and tells you to run `npm --prefix <part> install`.
- The hooks are turned on by `npm install` at the repo root, which runs husky's `prepare` script and sets `core.hooksPath` to `.husky/_`. A fresh clone has no hooks until you run it.
- To skip the hook in an emergency, use `git commit --no-verify`. Don't make a habit of it: CI will run the same checks once it exists.
- Git clients that don't load your shell profile (some GUIs) may not find `npm` from nvm. Husky reads `~/.config/husky/init.sh` before every hook, so you can add your nvm setup there.
