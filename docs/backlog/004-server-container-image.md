# 004: Container image for the server

Status: **ready**. Ticket design doc: it moves to `docs/features/` in the PR that builds it.

## Summary

Package the API server as an OCI container image, so it runs the same way on any host, and later on Kubernetes. The image is built with podman. CI builds and smoke-tests it on every PR. Each server release (`server-vX.Y.Z` tag, created by release-please) publishes it to the GitHub Container Registry (GHCR). This is the first step toward CD and GitOps (see the backlog). Nothing changes in the server's behavior or API.

## Concepts

- **OCI image:** the standard container image format. Podman, Docker, and Kubernetes all run it, so a podman-built image needs no changes for Kubernetes.
- **`Containerfile`:** podman's name for the build recipe, the same format as a Dockerfile.
- **GHCR:** GitHub's container registry, `ghcr.io`. A workflow can push to it with its own `GITHUB_TOKEN`, so no extra secret is needed.
- **Digest:** an image's content hash, `sha256:…`. Unlike a tag, it can never point at different content.

## The image

- **File:** `server/Containerfile`, with `server/` as the build context. Also add `server/.containerignore`, which excludes `node_modules/`, `data/`, `.env`, and `test/`.
- **Base:** the official `node:24-alpine` image, **pinned by digest** with the tag in a comment, for the same reason actions are pinned by SHA (`AGENTS.md` rule 5).
- **Two stages:**
  1. **deps** runs `npm ci --omit=dev`.
  2. **runtime** copies `node_modules`, `package.json`, and `src/`.

  The server runs TypeScript directly with Node's type stripping, so there's no build step and the image contains no dev dependencies.
- **Runs as** the non-root `node` user from the base image.
- **Command:** `node src/server.ts`. It uses no `--env-file`: in a container, configuration comes from environment variables.
- **Defaults set in the image:**
  - `HOST=0.0.0.0` and `PORT=3000`, with `EXPOSE 3000`
  - `DB_PATH=/data/test01.db`, where `/data` is a volume owned by `node`

  All other settings (`MIN_APP_VERSION`, `VALKEY_URL`, `TRUST_PROXY`) are unset unless given with `-e`. See [devops.md](../devops.md#server-environment-variables-optionally-from-serverenv).
- **Labels** (OCI annotations): `org.opencontainers.image.source` set to the repo URL, which links the GHCR package to the repo. Also `.version`, the server version, and `.revision`, the git commit, both passed in as build arguments.
- **No `HEALTHCHECK`:** it's specific to the Docker image format, and Kubernetes uses its own probes. Health is `GET /api/health`, which returns `200 {"status":"ok"}`.
- **Architecture:** `linux/amd64` only for now. Add arm64 when a host needs it.

## CI

- **Every PR and push to `main`:** a new `server-image` job in `ci.yml`:
  1. Build the image with podman, which comes with the `ubuntu-24.04` runners. Don't push it.
  2. Start it.
  3. Wait for `GET /api/health` to return 200.
  4. Check that `GET /api/v1/meta` reports the `serverVersion` from `server/package.json`.
  5. Stop it.

  The job's permissions stay read-only.
- **Publishing:** a new workflow, `.github/workflows/server-image.yml`.
  - It runs on `push` of tags matching `server-v*`. release-please creates those tags with the App token, and unlike `GITHUB_TOKEN` events, they do trigger workflows.
  - It also runs on `workflow_dispatch` against a tag, so an existing release such as `server-v0.2.0` can be published by hand.
  - It builds the image as above, then pushes `ghcr.io/jd-cookie/test01-server:<X.Y.Z>` and `:latest`.
  - Only this job gets `packages: write`. It logs in with its `GITHUB_TOKEN`, passed on stdin, never on the command line.
  - It checks that the tag's version matches `server/package.json` at that commit, and fails if they differ.
  - Actions are pinned by SHA, as usual.

## Decisions made for this ticket

Change these before claiming if you disagree:
- **The GHCR package is public.** The repo is public, and Kubernetes can then pull without a pull secret. After the first publish, the user sets the package's visibility to public in GitHub, because new packages start private. This step goes in devops.md.
- **The tags are `X.Y.Z` and `latest`.** No `X.Y` or `X` tags yet.
- **Only `server-v*` tag pushes publish.** Tag protection, meaning a ruleset that lets only the release App create `server-v*` tags, is listed in devops.md as a follow-up rather than built here.

## Security and configuration

- The image contains no secrets, and none are passed in when it's built.
- The process runs as the non-root `node` user, and only `/data` needs to be writable.
- `packages: write` is granted to the publish job only. The PR job can't push.

## Implementation map

- `server/Containerfile` and `server/.containerignore`
- `.github/workflows/ci.yml`: the `server-image` job
- `.github/workflows/server-image.yml`: publishing
- `docs/devops.md`:
  - how to build and run the image locally with podman, including the data volume
  - the CI and publishing jobs
  - the package visibility step
  - an update to the "Containers" note
- `README.md`: a short "Run the server in a container" section

## Acceptance checks

1. `podman build -t test01-server server/` succeeds on the dev machine.
2. `podman run --rm -p 3000:3000 -v test01-data:/data test01-server` starts the server. `GET /api/health` returns 200, and `GET /api/v1/meta` reports the version from `server/package.json`.
3. An account created through the containerized server is still there after the container is removed and started again with the same volume.
4. The process in the container runs as `node`, not root (`podman exec … id -u` ≠ 0).
5. The image contains no `test/`, `.env`, `data/`, or dev dependencies such as `typescript`.
6. On a PR, the `server-image` job builds and smoke-tests the image and pushes nothing.
7. A `server-v*` tag, or a manual run against `server-v0.2.0`, publishes `ghcr.io/jd-cookie/test01-server:<version>` and `:latest`. The image's labels have the right source, version, and revision.
8. A tag whose version doesn't match `server/package.json` fails the publish job, and nothing is pushed.
9. actionlint is clean, `npm run check` passes, and devops.md describes all of the above.
