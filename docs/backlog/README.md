# Backlog

Feature and work requests that aren't built yet. Each item has one row here. When an item gets a design doc, its title links to it.

## How it works

- **Adding an item:** add a row to the table, with status `idea`. A design doc is optional at first.
- **Designing an item:** write `docs/backlog/<slug>.md`, for example `password-reset.md`, link the title to it, and set the status to `designed`. Use the same sections as a feature doc (see [../README.md](../README.md#writing-a-feature-doc)), and fill in as much as is known. The implementation map and acceptance checks can wait.
- **Starting work:** set the status to `in progress`.
- **When it's built:**
  1. Move the design doc to `docs/features/NNN-<slug>.md`, using the next free number, and bring it up to date with what was actually built. Items without a design doc get a feature doc written at this point.
  2. Add it to the Features table in [../README.md](../README.md#features).
  3. Delete its row here.
  4. Update any links to the old path.
- **Dropping an item:** delete the row and its design doc, and note why in the commit message.
- **Order:** rows are roughly in priority order, highest first. Reorder freely.

Statuses: `idea` (no design doc yet), `designed` (has a design doc), `in progress`.

## Items

| Item | Area | Status | Notes |
|---|---|---|---|
| Decide what the app does beyond accounts | Product | idea | The project is for learning, so pick features that give the technology below real work to do: data worth tracing, deploys worth automating. |
| OpenTelemetry | Observability | idea | Traces, metrics, and logs from the server, and maybe from the app too. Needs a collector and somewhere to view the data. Not designed yet. |
| Container image for the server | DevOps | idea | A `Containerfile` built with podman. It's the first step toward CI/CD and Kubernetes. |
| CI on GitHub Actions | DevOps | idea | Run the tests, lint, and typecheck on every push, and build and publish the server image to a registry, for example GHCR. The repo is on GitHub now. |
| Local Kubernetes cluster | DevOps | idea | Suggested: k3s on the dev machine. It's a full Kubernetes distribution with its own container runtime, so it doesn't need Docker. Podman-built images run on it unchanged. Staging would run here. |
| GitOps deploys (CD) | DevOps | idea | The desired state of each environment is declared in git, and a tool in the cluster, Argo CD or Flux, applies it automatically. Depends on the server image, CI, and the cluster. Not designed yet. |
| Rate limiting of login and signup | Server, security | idea | Password guessing isn't throttled right now. Keep the counters in Valkey, not process memory, so they hold across instances. Gap from [001](../features/001-accounts.md#security). |
| Password reset | Accounts | idea | Needs a way to send email, shared with email verification. Gap from [001](../features/001-accounts.md#security). |
| Email verification | Accounts | idea | Needs a way to send email, shared with password reset. Gap from [001](../features/001-accounts.md#security). |
| Staging/production database and Valkey | Server, DevOps | idea | Choose the database. Add a database layer so SQLite (development and tests) and the server database share one code path. Make migrations portable, and run them once per deploy rather than on each instance's startup. Run the test suite against both databases. Add a Valkey connection setting. Needed before running more than one server instance. See [../devops.md](../devops.md#environments). |
| Production hosting with HTTPS | DevOps | idea | Choose a host, then set the production `API_URL`. See [../devops.md](../devops.md). |
| HTTPS for development and staging | DevOps, security | idea | Both use plain HTTP on the LAN today. Gap from [001](../features/001-accounts.md#security). |
| Delete expired session rows | Server | idea | Housekeeping only: expired sessions are already rejected. Gap from [001](../features/001-accounts.md#security). |
| Run the app in a web browser for UI work | Dev tooling | idea | Optional. SecureStore has no web version, so this needs a development-only fallback, plus `react-native-web` and `react-dom`. |
| Over-the-air updates (EAS Update) | DevOps | idea | Right now every app change needs a new APK. See [../devops.md](../devops.md#known-gaps-and-caveats). |
| iOS build profile | DevOps | idea | Bundle IDs exist already. Needs an Apple Developer account. See [../devops.md](../devops.md#known-gaps-and-caveats). |
