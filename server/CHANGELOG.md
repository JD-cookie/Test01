# Changelog

All notable changes to the Test01 **server**. New entries are written by release-please from [Conventional Commits](https://www.conventionalcommits.org) when a release PR is merged; see `docs/devops.md` ("Versioning and releases"). Versions follow [SemVer](https://semver.org).

## 0.1.0 (2026-11-12)

First version, from before the release process existed.

### Features

* Accounts: sign up, log in, stay logged in, log out, under `/api/v1/auth/*` and `/api/v1/me` ([001](../docs/features/001-accounts.md))
* API versioning: the `/api/v1` prefix, `GET /api/v1/meta`, `GET /api/health`, and `MIN_APP_VERSION`, which returns `426 UPGRADE_REQUIRED` to apps that are too old ([devops](../docs/devops.md))
