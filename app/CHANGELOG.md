# Changelog

All notable changes to the Test01 **app**. New entries are written by release-please from [Conventional Commits](https://www.conventionalcommits.org) when a release PR is merged; see `docs/devops.md` ("Versioning and releases"). Versions follow [SemVer](https://semver.org). The Android build number (`versionCode`) is separate and set by EAS on every build.

## 0.1.0 (2026-11-12)

First version, from before the release process existed.

### Features

* Accounts: Log in, Create account, and Home screens, with the session kept in secure storage across restarts ([001](../docs/features/001-accounts.md))
* Development, staging, and production variants, each with its own app ID and server address. Non-production builds show a footer with the variant, version, and server. An "Update required" screen appears when the server reports the app is too old ([devops](../docs/devops.md))
