# Test01

A mobile app (Expo / React Native, for Android now and iPhone later) with its own backend (Node + Fastify + SQLite).

- `app/`: the mobile app
- `server/`: the backend API
- `docs/`: the system spec, with one document per feature. **Start at [docs/README.md](docs/README.md).**

## Requirements

- Node 24+ on the development machine
- An Android phone on the **same Wi-Fi** as the development machine

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

```bash
cd server && npm test && npm run typecheck
cd app && npm run lint && npm run typecheck
```
