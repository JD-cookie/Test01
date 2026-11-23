# Project status

Last updated 2026-11-22. This is a handoff note between working sessions. The system spec is in `docs/`; this file tracks where the work stands. Keep one fact or next step per line, so updates change a line rather than rewrite a paragraph.

## Where things are

- **Qodo hackathon** ("Build a Software Factory in 30 Days", 2026-11-02 to 2026-12-02). The user is entering with this project.
  - 23 weekday challenges. Missed ones can be caught up before the final cutoff, midnight Pacific at the end of Dec 2.
  - Each challenge gets a focused branch and PR with a Qodo review. The user posts each submission in that challenge's Discussion.
  - Rules: https://hackathon.qodo.ai/rules/. Submission template: https://github.com/orgs/qodo-hackathon/discussions/1.
- **Day 1** (rate limiting, feature 002): https://github.com/orgs/qodo-hackathon/discussions/2
  - Merged in PR #1 (https://github.com/JD-cookie/Test01/pull/1).
  - Done: the user posted a screen capture in the Discussion (2026-11-17).
- **Day 2** (AGENTS.md with 3–5 rules, imported into Qodo as Review Standards, and one rule nominated in the Day 2 Discussion):
  - Merged in PR #5 (2026-11-13): https://github.com/JD-cookie/Test01/blob/main/AGENTS.md.
  - Done: the user confirmed Qodo's Review Standards have the five rules (2026-11-17).
  - **Next (user):** post the nomination in the Day 2 Discussion. Suggested: "Count Before You Check", from Qodo's Day 1 finding.
- **Day 3** (connect the backlog to the agent, and work tickets one per branch and PR). The user chose to keep the backlog in the repo rather than an external tracker.
  - PR #7 (merged 2026-11-16): the backlog is the ticket system, with a `ready` status, a number given when a ticket is marked ready, and claims made by creating the ticket's branch. Adds `scripts/ticket.sh` (`list`, `claim next`, `claim NNN-slug`, `verify`) and the `next-ticket` skill (in `.agents/skills/`, with `.claude/skills` a symlink to it, so Claude Code, Codex, and opencode all find it).
  - PR #8 (merged 2026-11-17): a designed backlog item for a `refine-ticket` skill (Definition of Ready, interview with `grilling`, vertical slices, adversarial review with evidence from two reviewers in round 1 and then the more useful one, then the user's approval before `ready`), compared against Matt Pocock's skills and pstack. Also adds the `grilling` skill, copied from Matt Pocock's skills (MIT, pinned to upstream commit 7739eae).
  - PR #9 (merged 2026-11-17): marks `refine-ticket` ready as ticket 003, at the user's request. `scripts/ticket.sh list` shows `003-refine-ticket-skill  ready`.
  - Designed, not ready: the server container image. (Delete expired sessions is now ticket 004.) The user moved both back from `ready` before #7 merged.
  - PR #10 (merged 2026-11-18): ticket 003, the `refine-ticket` skill and the Definition of Ready. Qodo's 13 findings were all fixed. Every acceptance check has now passed: 2 on the real refinement of 004, 3 (the user says no) in a scripted run, 2026-11-19.
  - Added during #10's review, at the user's request: the row recheck in step 9.6, the Item-column match, `awk -v c=…` so Claude Code's argument substitution can't rewrite `$2`, and the opencode model rotation with a results table (`.agents/skills/refine-ticket/reviewers.md`).
  - Refinement of "Delete expired session rows": four review rounds (Codex and opencode in rounds 1 and 4, opencode in 2 and 3): 21 findings kept and 1 dropped, all fixed, recorded in the doc and in `reviewers.md`.
  - The user approved it on 2026-11-18, after round 4. It's ticket 004, marked ready in PR #11 (merged 2026-11-19). `scripts/ticket.sh list` shows `004-delete-expired-sessions  ready`.
  - 003's checks 2, 3, 4, 9, and 10 recorded in its "Delivery and review", in PR #12 (merged 2026-11-19). 003 is `implemented`.

- **Day 4** (make the agent pick up work automatically, from a schedule or a tag; one small ticket; it builds, runs the checks, opens a PR for Qodo, fixes confirmed findings, with a retry limit; the user merges).
  - #10 doesn't qualify: it was started in a session. The ticket for it is 004, "Delete expired session rows".
  - Checked 2026-11-18: systemd's user manager runs, and the account has linger on, so a user timer runs while logged out. Every PR so far is from the user's account except release-please's, which Qodo didn't review.
  - The user answered the six runner questions (2026-11-18): yes to all, with 4 Qodo rounds instead of 3, and an install script for the timer. They also asked for a backlog idea: code reviews by our own agents, reusing existing review skills.
  - The runner doc went through review rounds 1 and 2 (Codex gpt-6.1-sol, opencode kimi-k3.1-pro; all findings fixed or asked; Q1–Q8 answered). Decisions: GitHub App `JD-cookie-Agent` (bot `jd-cookie-agent[bot]`), local names `jd-cookie-agent`, checks in `bwrap`, Claude permission rules for the agent (own Linux user and a credential broker are backlog ideas), WebFetch limited to doc sites, ruleset on `main`.
  - Split 2026-11-19 (the user agreed) into three tickets, all `designed`, on local branch `refine-agent-runner` in the scratchpad worktree (b05cc1a, not pushed): `agent-build.md` (run by hand: claim, build, checks, PR), `agent-review-rounds.md` (blocked by it), `agent-timer.md` (blocked by both; its real run on 004 is Day 4). The two rounds' record is in `agent-build.md`.
  - The user moved `app.pem` and `app.env` to `~/.config/jd-cookie-agent/` (folder 700, files 600), checked 2026-11-19.
  - Review rounds 3 and 4 of `agent-build.md` (Codex gpt-6.1-sol, opencode deepseek-v4-pro): 13 and 11 kept, 0 dropped; round 4 committed ef6d4b2. Probed: commitlint needs its config in the clone (`.agent/`); `bwrap --unshare-net` works; no TCP listener inside the sandbox; `format-patch` drops merges (bundle instead). Q9 answered yes (2026-11-19): a second small ticket (not 004), refined and marked ready after part 1 merges, run by hand as part 1's check 9; committed a1598d2. Round 5 (Codex only): 2 kept and fixed (the setup's network check now reads `/proc/net/dev` instead of a listener; the second ticket's row goes above 004's so `claim next` takes it); committed. The user wants to read it in a PR first: opened from `ready-005` (number reserved) with part 1 still `designed`; the ready commit (rename to `005-agent-build.md`, row, status) is added to the same PR only after the user approves, before they merge.
  - **Next:** finish refining `agent-build.md` (round 5), mark it ready, build it; then pick and refine the second small ticket and run part 1 by hand; then parts 2 and 3 the same way; then install the timer and let it build 004. The Day 4 note needs: trigger and source link, ticket and PR, checks, Qodo review, retries, where the user stepped in.

- **Purpose:** a learning project, for exploring technology the user hasn't worked with before: phone apps, GitOps, OpenTelemetry, and more. Build things the real way, and explain new technology as it's introduced.

- **Repo:** `/home/groot/Share/dev/git/feisty`.
  - The project was renamed **test01**, but the directory keeps its old name on purpose.
  - Feature branches are named after their ticket, `NNNN-<slug>`, with a four-digit number. The number is given when the ticket is marked `ready` (see `docs/backlog/README.md`).
  - Remote `origin` is `git@github-test01:JD-cookie/Test01.git` on GitHub, reached over SSH through a write-enabled **deploy key** for this repo only (`~/.ssh/github_test01`, with an `~/.ssh/config` alias `github-test01`). The repo is **public**.
  - The `gh` CLI (2.46) is logged in as `JD-cookie` with a fine-grained token limited to Test01. It can read the repo and create PRs, but not Actions secrets, variables, or admin settings. Its config is in `~/.config/gh/hosts.yml`. `gh` resolves the `github-test01` alias without needing `-R`.
- **Stack:**
  - App: Expo SDK 58 with React Native, TypeScript, and Expo Router, in `app/`.
  - Backend: Node 24 with Fastify and `node:sqlite`, in `server/`. Optional Valkey (`VALKEY_URL`, client `iovalkey`) for rate-limit counters.
  - Spec: `docs/`.
  - Backlog: `docs/backlog/README.md` lists work not built yet, with design docs alongside it.
- **Done:**
  - Feature 001, accounts: sign up, log in, stay logged in, log out. Spec in `docs/features/0001-accounts.md`.
  - Feature 002, rate limiting of login and signup: limits per client (an IPv4 address or an IPv6 /64) and per client+email for failed logins. Counters are in Valkey when `VALKEY_URL` is set, otherwise in memory, and the limiter fails open. `TRUST_PROXY` is supported. Spec in `docs/features/0002-rate-limiting.md`. Merged in PR #1, released as server 0.2.0.
  - Environment support: dev, staging, and production app variants, the `/api/v1` prefix, the `X-App-Version` header with a `MIN_APP_VERSION` check that shows the "Update required" screen, and `/api/v1/meta`. Spec in `docs/devops.md`.
  - Device setup guides: `docs/dev-setup-phone.md` and `docs/dev-setup-android-studio-ubuntu.md`.

## Verified

- Server: typecheck is clean. `npm test` runs 23 tests, and all pass. The 3 Valkey tests are skipped unless `VALKEY_URL` is set. With Valkey 9 running in podman, all 26 pass. CI runs them with a Valkey service.
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

- **Merged PRs** (all squash-merged with the PR title):
  - 2026-11-13: #2 (husky), #3 (CI, Conventional Commits, release-please), #1 (rate limiting), #4 (release-please's release PR), #5 (AGENTS.md), #6 (the PR title check uses the base branch's commitlint rules, which covers the Qodo finding on #3 that was left open).
  - 2026-11-16: #7 (the backlog as the ticket system, `scripts/ticket.sh`, the `next-ticket` skill), after Qodo reviewed every push and each finding was fixed.
  - 2026-11-17: #8 (the `grilling` skill and the `refine-ticket` design), with both Qodo findings fixed. #9 (ticket 003 marked `ready`, and this file restructured to one fact per line).
  - 2026-11-18: #10 (ticket 003, the `refine-ticket` skill).
  - 2026-11-19: #11 (ticket 004, "Delete expired session rows", marked `ready`). Qodo found no issues.
  - 2026-11-19: #12 (ticket 003's last acceptance checks; 003 is implemented). Qodo found no issues.
- **Merged 2026-11-19:** #14, two reviewers in every refine-ticket round, stopping on blocking findings, ask after 5 rounds (f7f558e). Ticket 0003's check 2 passed for those rules in ticket 0006's refinement (recorded in `docs/tickets/0003-refine-ticket-skill.md`).
- **Merged 2026-11-22:** #17 (604e8e2), the runner design in three parts, all `designed`. The user approved part 1 on 2026-11-22; it's marked `ready` in its own PR once 0006 is built (it's blocked by 0006). 0005 is free again.
- **Open PRs:** #18, building ticket 0006 (branch `0006-spec-and-tickets`, claim `8a067552`): spec docs in place with Changes lists, built ticket docs in `docs/tickets/`, 0003 converted. Checks 1 to 6 pass. In review. After it merges: mark the runner's part 1 `ready` (its blocker is then built), then build it; it's check 7 of 0006.
- **Merged 2026-11-20:** #15 (ticket 0006 marked `ready`), #16 (four-digit ticket numbers; the release changelogs' links to the accounts doc were edited once, with the user's approval, as an exception to rule 4).
- **Ticket 0006, Keep the spec separate from the ticket history:** `ready` (PR #15 merged 2026-11-20). Build it next, before the runner's part 1; until it merges, the user starts no other ticket builds. Its worktree `scratchpad/wt-spec` (branch `ready-006`) can be removed.
- **Release process:** works end to end.
  - Merging #1 made the App open #4, which bumped the server to 0.2.0 (`package.json`, the lockfile, the manifest, and `server/CHANGELOG.md`) and left the app at 0.1.0. CI ran on it.
  - Merging #4 created the tag `server-v0.2.0` and the GitHub Release "server: v0.2.0".
  - Qodo is set not to review bot PRs, so release PRs get no Qodo review.
  - `237065b` (both parts at 0.1.0) is tagged `server-v0.1.0` and `app-v0.1.0` (annotated, 2026-11-17), so the 0.2.0 compare link works.
  - App Client ID `Iv23liyEkVVtGp2Shoka` (not secret).
- **Next (user):** on the phone, confirm that staying logged in (kill and reopen the app) and logging out both work.
- Everything else (what the app does beyond accounts, password reset, production hosting, and so on) is in `docs/backlog/README.md`. Pick from there.

## Working agreements and gotchas

**The project rules, setup, and verify commands are in [`AGENTS.md`](AGENTS.md)** (`CLAUDE.md` imports it): Count Before You Check, No Shared State in Process Memory, Every Feature Ships With Its Doc, Release Tooling Owns Versions and Changelogs, and Least-Privilege Workflows. Don't repeat them here. Below are only the notes about this machine and how the user likes to work.

- New requests and known gaps go in `docs/backlog/README.md`, not in this file.
- Don't offer to commit every small change: the user batches commits. PR work (branch, commit, push, PR) is fine when the user asked for the work.
- After creating or updating a PR, check it about 10 minutes later for reviews, comments, and checks, then 30 minutes after that if nothing changed. Qodo doesn't review bot PRs, such as release-please's.
- `gh` 2.46: `gh pr edit` fails (a Projects classic error). Update PRs with `gh api -X PATCH repos/JD-cookie/Test01/pulls/N`.
- `app/.npmrc` sets `legacy-peer-deps=true` to get past a `react-dom` 19.3.1 / `react` 19.3.0 peer conflict in SDK 58.
- **Containers: podman, not Docker** (podman 5.7 and buildah are installed). The user has done manual Linux server deploys and some GitHub Actions CI, but has little experience with CD, GitOps, or Kubernetes. Explain those from the basics.
- The dev server has no GUI, Java, Android SDK, Docker, or Kubernetes tools. Builds go through EAS in the cloud. Devices connect over the LAN at `10.0.0.78` or through an SSH tunnel with `adb reverse`.
