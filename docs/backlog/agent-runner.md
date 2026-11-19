# An agent that builds ready tickets on a timer

Status: **designed**. When the user marks it `ready`, it gets a number and this doc is renamed `NNN-agent-runner.md`. It moves to `docs/features/` in the PR that builds it.

## Summary

Today an agent builds a ticket only when the user opens a session and asks. This feature adds a **runner**: a script that a systemd timer starts every 15 minutes on the user's machine. Each run looks at where the work stands on GitHub and does the next step:
- claim the next free `ready` ticket and build it
- get the checks green
- open a PR for Qodo to review
- fix the findings it confirms

It stops and asks for help when it reaches a retry limit. The user still decides what's `ready` and still merges every PR.

It's for the user, who wants tickets built without starting each one by hand. It's also the project's first automation that acts on its own, so it shows what an agent can do unattended and where it gets stuck.

What doesn't change:
- how tickets are made `ready`
- the claim rules in `scripts/ticket.sh`
- the `next-ticket` skill, which the runner's agent follows
- the review rules: Qodo reviews every PR, and every finding is fixed or answered
- the user merges

### Out of scope

- Marking tickets `ready`, refining them, or merging PRs.
- More than one ticket at a time, or more than one runner per machine. Runners on two machines don't collide, since each works only on its own claims (`runner-<machine id>`), but only one machine is meant to run it.
- Running in GitHub Actions or the cloud (see "Decisions made for this ticket").
- Reviews by our own agents. That's its own backlog item: "Code reviews by our own agents".
- Notifying the user outside GitHub. The runner is its own GitHub identity, so GitHub notifies the user of its PRs and comments as for anyone's.
- Starting on a label or a push instead of a timer. A timer is enough for one ticket at a time.

## Concepts

- **Runner:** `scripts/agent-run.sh`. One run does one step and exits. It holds no state of its own between runs: the state is in GitHub, in the ticket's branch, its PR, the PR's labels and comments, and Qodo's review.
- **Timer:** a systemd **user** timer. systemd is Linux's service manager. A user timer runs under the user's own account, with no root. With "linger" on (`loginctl enable-linger`), it runs while the user is logged out too.
- **Agent:** Claude Code in headless mode (`claude -p`), run by the runner in the runner's own clone of the repo.
- **Round:** one pass of the agent over the review results of one push: Qodo's findings and failed CI jobs. It ends with a push, or with "nothing left to fix".
- **`needs-help`:** a PR label. The runner adds it when it stops for the user, and does nothing more on that PR while it's there.
- **The runner's marker:** every comment and reply the runner posts ends with a hidden `<!-- jd-cookie-agent ... -->` marker. It records which commit a round reviewed and pushed, and when it collected the comments (see "The runner's records" under "Review step").
- **The App:** `JD-cookie-Agent`, a GitHub App installed only on this repo, made by the user on 2026-11-19. GitHub derives its bot user from the name, in lower case: `jd-cookie-agent[bot]`, user id 358547770 (`gh api 'users/jd-cookie-agent[bot]'`). On this machine, the runner's folders, systemd units, lock file, and comment marker use the same name, `jd-cookie-agent` (renamed from `test01-agent` on 2026-11-19, at the user's request, so there's one name for one thing). It's the runner's identity on GitHub: its PRs, comments, labels, and pushes come from `jd-cookie-agent[bot]`, not from the user.

## User-facing behavior

For the user:
1. Install and start the timer once per machine: `scripts/agent-timer.sh install`. `scripts/agent-timer.sh status` shows the timer and the last run's log. `scripts/agent-timer.sh uninstall` stops it and removes it.
2. Mark a ticket `ready` as usual. Within 15 minutes, the runner claims it.
3. Follow it on GitHub: its PR carries the label `agent-run`. Each round adds two comments from the runner: `Agent round N started`, then `Agent round N` with what it did. When it's done, it comments `Ready for review by the user.`
4. If it stops for help, the PR gets the label `needs-help` and a comment that says why. To let it go on, fix what's needed, then remove the label. Removing it resets the retry counts.
5. Merge, or close the PR, as for any PR.

The runner pushes, opens PRs, and comments as the App `jd-cookie-agent[bot]` (see "The App's token"). So the user gets GitHub's notifications for them, and can review its PRs like anyone else's. Qodo reviews them once the user has turned on bot reviews in Qodo, with release-please's App on Qodo's skip list (see "Tasks for the user"): Qodo didn't review release-please's PR #4, because bot reviews were off.

## Processing

### One run

`scripts/agent-run.sh` takes no arguments. It works in its own clone, `${XDG_DATA_HOME:-$HOME/.local/share}/jd-cookie-agent/repo`, and never in the user's checkout. It clones `origin` there if that clone doesn't exist. Its agent name for claims is `runner-<id>`, where `<id>` is the first 12 characters of `/etc/machine-id`, which is unique to each installed system, unlike a short host name.

The runner's own code is a copy: `install` copies `agent-run.sh`, `agent-token.sh`, and `scripts/agent-run/` (the prompts and `settings.json`) to `${XDG_DATA_HOME:-$HOME/.local/share}/jd-cookie-agent/bin/`, and the service runs that copy. The agent can edit everything in the clone, so nothing the runner trusts is read from it: not its scripts, prompts, or Claude settings, and not the commitlint config (see the title check). Running `install` again updates the copy, after the user has merged a change to the runner.

1. **Lock.** It takes `flock -n` on `${XDG_RUNTIME_DIR}/jd-cookie-agent.lock`. If another run holds it, it exits 0. systemd doesn't start a service that's still running, either. The lock also covers runs started by hand. The lock is per machine. A runner on a second machine has another agent name, so it only works on its own claims (step 2), and the two never touch the same PR.
2. **Find its work.** It looks only at its own tickets: branches on `origin` whose claim commit, the first commit after `main` on the branch, has the trailer `Claimed-By: runner-<host>` with its own agent name. For each one, it looks up the branch's PRs in every state (`gh pr list --head <branch> --state all`):
   - **A merged or closed PR:** that ticket is over. Skip it. The user deletes its branch when they like; until then, the claim keeps other agents off it.
   - **An open PR with `needs-help`:** nothing to do on it.
   - **An open PR without `needs-help`:** review step (below).
   - **No PR:** an earlier run died while building, for example in a reboot, or `gh pr create` failed after the push. Stop for help, as in "Stopping for help": if the clone still has the branch with commits that `origin` doesn't, they're saved and pushed; then the draft PR opens, with the comment "A run stopped while building this ticket. Its work so far is on this branch." It's the same every time it runs, so a run that dies partway through it is finished by the next.
   - **None of its tickets has an open PR:** if `scripts/ticket.sh list` shows a free `ready` ticket, build step (below). If not, log `no ready ticket` and exit.

   Only one ticket is in progress at a time: the runner doesn't start a new one while any of its PRs is open, `needs-help` or not.
3. **A token for each phase.** It makes a new App token (see "The App's token") right before each group of GitHub calls and pushes: when it finds its work, after each agent run, and before each push. Each token lasts an hour, and a run can last longer: three agent tries of up to 45 minutes each.

### Build step

1. In the clone: `git fetch`, then switch to a clean `main` at `origin/main`, and delete every other local branch: the clone is the runner's own, and what matters is on `origin`. A local branch left by a run that failed would make the next claim fail. Then `npm ci` at the root and in `server/` and `app/`, so the hooks and checks run as in CI.
2. `scripts/ticket.sh claim next "runner-$(hostname -s)"`. Its exit codes (see `scripts/ticket.sh`):
   - **0:** claimed. The script has already pushed the claim branch, `NNN-slug`, whose commit has the trailer `Claimed-By: runner-<host>`.
   - **3:** no free ticket. Exit 0.
   - **5:** claimed, but the ticket was withdrawn or changed on `main` meanwhile. Stop, as in "Stopping for help", with the script's message.
   - **anything else (2, 4):** log the message and exit 1. If the claim reached `origin` after all, the next run finds the branch with no PR, and stops for help.
3. **Build**, try 1 of 3: run the agent with the build prompt (see "The agent"). It follows the `next-ticket` skill's step 2, and commits, but doesn't push. If it wrote `.agent/stop.md`, stop, as in "Stopping for help", with `stop.md` as the comment.
4. **Checks:** the runner itself runs `npm run check` in the clone, in the sandbox (see "The agent"), with a time limit of 20 minutes (`timeout --kill-after=1m 20m`). A check that runs out of time is a failed try. The runner doesn't take the agent's word for it.
   - **Pass:** go to 5.
   - **Fail:** run the agent again with the fix prompt and the check's output (the last 200 lines), then check again. That's try 2, then try 3.
   - **Still failing after 3 tries:** stop, as in "Stopping for help", with "The checks still fail after 3 tries." and the last 200 lines of output.

   The tries are counted in the run itself. They can't repeat across runs: a run that dies mid-build leaves a branch with no PR, and the next run stops for help.
5. **The title:** the agent writes `.agent/pr.md`: the first line is the PR's title, the rest is its body, as `next-ticket` step 3 describes. The runner checks the title with commitlint and `main`'s config, as `pr-title.yml` does with the base branch's: `git show origin/main:commitlint.config.mjs` into the run's folder, then `printf '%s\n' "$title" | npx commitlint --config <that copy>`, in the sandbox. commitlint and its config are JavaScript the agent could have changed in the clone, so the check gets no token and no network. At worst it passes a bad title, and `pr-title.yml` fails it in CI. If it fails, that's a failed check, with commitlint's output, and goes to the fix prompt like the others.
6. **Push and open the PR:** push the branch, then `gh pr create --label agent-run` with that title and body. Labels are added and removed later with `gh api` (`repos/<owner>/<repo>/issues/<n>/labels`), because `gh pr edit` fails in the installed `gh` 2.46. A push that GitHub refuses because the branch changes `.github/workflows/` stops the build, as in "Stopping for help". If `gh pr create` fails after the push, the run exits 1, and the next run finds the branch with no PR.

### Stopping for help

Whenever the runner stops for the user, before or after the PR exists, it does the same:
1. **Save the work.** In the run's folder, `${XDG_STATE_HOME:-$HOME/.local/state}/jd-cookie-agent/runs/<UTC time>/`, it writes `commits.patch`, from `git format-patch --binary --stdout origin/<branch>..HEAD` (empty if the branch is on `origin` already), and `uncommitted.patch`, from `git add -A` and `git diff --cached --binary HEAD`, then `git reset -q`. `git add -A` takes untracked files too, except ignored ones, and `--binary` makes both patches apply with `git apply` or `git am` in a fresh clone.
2. **Push** the branch if it has commits that `origin` doesn't, unless the reason for stopping is that GitHub refused the push (a workflow change). Then `origin` keeps only what's there, and the comment names the patch files.
3. **Before a PR exists,** open a draft PR from the branch with the labels `agent-run` and `needs-help`, with the title from `.agent/pr.md` if it passes the title check, or else `chore(repo): build ticket NNN-slug`. **After,** add `needs-help` to the PR.
4. **Comment** the reason, the run folder's path, and the last 200 lines of output if there are any.

When the user removes `needs-help`, the next run goes on with the review step. A draft PR is marked ready for review (`gh api graphql`, `markPullRequestReadyForReview`) before the runner posts `Ready for review by the user.`

### Review step

For the open PR without `needs-help`.

**The runner's records.** Everything it posts ends with a hidden marker, `<!-- jd-cookie-agent ... -->`, holding the fields below. Every run reads them back from the PR's comments, by `jd-cookie-agent[bot]` only. Every list it reads from GitHub (comments, review comments, reviews, the timeline, checks) is read in full, with `gh api --paginate`.
- `Agent round N started`, posted before the agent runs: `round=N reviewed=<sha>`, where `reviewed` is the head commit Qodo reviewed. It counts toward the limit, but it doesn't mark the head as done: only a finished round does.
- `Agent round N`, posted when the agent and the checks are done, **before** the push: `round=N reviewed=<sha> cutoff=<time> pushed=<sha>`. `cutoff` is when the runner collected the round's input. `pushed` is the commit the round will push, or the same head if there's nothing to push. The agent's replies to inline comments are in the marker, as JSON. Posting the report before the push means a crash can't lose it: the next run finds `pushed` missing on `origin` and finishes the push (step 1).
- `Ready for review by the user.`: `ready=<sha>`.

The **last finished round** is the newest `Agent round N` comment, without "started".

Steps:
1. **Finish what the last run started.**
   - If the last finished round's `pushed` isn't on `origin`: if the clone has that commit, push it. If not, stop for help: "Round N's commits were lost before the push."
   - If its marker has replies that aren't posted yet (no reply by the App on that comment with the marker `round=N`), post them.
   - An `Agent round N started` with no `Agent round N` after it is a round that died before its report. It counts toward the limit (step 5), and nothing else: its head still needs a round.
2. **Wait for the review.** Qodo is done with the head commit when its review comment, the issue comment by `qodo-code-review[bot]` whose body contains `<h3>Code Review by Qodo</h3>`, contains `<!-- https://github.com/<owner>/<repo>/commit/<head sha> -->`. Qodo's comments start with a blank line or with the heading, so the runner matches the heading anywhere, never as a prefix. Its other comment, `<h3>PR Summary by Qodo</h3>`, names the same commit, and doesn't count. CI is done when `gh pr checks` lists at least one check and none is pending. No checks at all means CI hasn't started yet.
   - **Either isn't done:** exit, and check again next run.
   - **Still not done 60 minutes after the head commit was pushed:** stop for help: "Qodo or CI hasn't finished reviewing <sha> after 60 minutes." The push time is the time of the finished round whose `pushed` is that commit, or the PR's creation time for the first head.
3. **Collect what's new since the last finished round's `cutoff`** (or since the PR opened), for the round prompt. A comment, review comment, or review counts as new if its `updated_at` is after the cutoff, so an edited one counts too:
   - Qodo's whole review comment: some findings are only there.
   - Everything by `qodo-code-review[bot]` and by the repo owner (`gh api repos/<owner>/<repo> --jq .owner.login`): inline review comments, the PR's own comments, and the bodies of reviews (`pulls/<n>/reviews`), such as a "Request changes" with no inline comment.
   - For each failed CI job, its failed log lines (`gh run view <id> --log-failed`, the last 200 lines).

   Comments from anyone else are left out: the repo is public, so anyone can comment, and the agent would read their text as instructions. The runner's own comments, by `jd-cookie-agent[bot]`, are left out too.
4. **Is a round needed?** A round runs if any of these holds:
   - no finished round has `reviewed` equal to the head commit
   - step 3 found a new comment or review
   - `needs-help` was removed after the last finished round
   - `origin/main` has commits the branch doesn't

   Otherwise exit. A red CI with nothing new doesn't start a round: the round that saw it already ran, and step 10 stopped for help if it couldn't fix it.

   So every head commit Qodo reviews gets one round, even when Qodo found nothing. The agent decides what's open, from the review comment and the other comments. It can't be read reliably from Qodo's comment alone: on PR #12, with no findings, it starts with counts (`🐞 Bugs (0)`, `📘 Rule violations (0)`, `📎 Requirement gaps (0)`). On PR #10, after every finding was fixed, it had no counts, only a "Resolved findings" list, each finding marked `✓ Resolved`.
5. **Count rounds.** Count the `Agent round N started` comments since the last time `needs-help` was removed from the PR (the PR's timeline, event `unlabeled`), or since the PR opened. That count includes rounds that died. If 4 are done, stop for help: "Qodo still has findings after 4 rounds." A round is counted before it runs, as rule 1 asks.
6. **Catch up with `main`:** switch the clone to the PR's branch at `origin`, and `git merge origin/main`, as `next-ticket` step 4 says (no rebase, so no force-push). If the merge has a conflict, `git merge --abort`, and stop for help: "Merging main has a conflict."
7. **Start the round:** post `Agent round N started`, with its marker. If that post fails, exit 1: no round runs unrecorded.
8. **Run the agent** with the round prompt and the collected text. If step 4 found only that `main` moved on, the agent still runs: the merge can break something, and the checks show it. The agent writes `.agent/round.md`, with each finding, whether it's confirmed, and what it did: fixed (with the commit) or answered (with the reason). It writes `.agent/replies.json`, with one reply for each inline comment collected in step 3: `[{"comment_id": 123, "body": "…"}]`. It updates the design doc's "Delivery and review" section, as `next-ticket` step 4 asks. If the title should change, it writes the new one as the first line of `.agent/pr.md`. If it wrote `.agent/stop.md`, stop for help, with `stop.md` as the reason.
9. **Checks** as in the build step, 3 tries, with the title check if `pr.md` changed. If they still fail, stop for help, with the output.
10. **Report, push, reply:** post `Agent round N`, with `round.md` and its marker. Then, if the round or the merge made a commit, push. If GitHub refuses it (a workflow change), stop for help. If the title changed and passes the title check, set it (`gh api -X PATCH repos/<owner>/<repo>/pulls/<n>`). Then post each reply as a reply to its comment (`gh api …/pulls/<n>/comments/<id>/replies`), each with the marker `round=N`. Then:
    - **It pushed:** exit. The next run waits for Qodo's review of the new head.
    - **Nothing to push, and CI green:** the round is the last. Mark a draft PR ready for review, and post `Ready for review by the user.` with the marker, once per head commit. If the user or Qodo comments again, a later run runs a round for it.
    - **Nothing to push, and CI red:** stop for help: "CI still fails, and round N changed nothing."

### The agent's files

`.agent/` in the clone is git-ignored. The runner empties it before each agent run, so an old file can't pass for a new one. After the run, it checks what the step needs. A missing or invalid file counts as a failed try:
- `pr.md`: a non-empty first line.
- `round.md`: not empty.
- `replies.json`: valid JSON, an array with exactly one object for each inline comment collected in step 3, no more, none twice, each with that comment's numeric `comment_id` and a non-empty `body`.

### The agent

Each run of the agent is a fresh `claude -p` process in the clone, with no MCP servers (`--strict-mcp-config`), a time limit of 45 minutes (`timeout 45m`), and its output saved to the run's log. Its permissions:
- **Allowed:** reading files, editing files in the clone, and these shell commands: `npm`, `node`, `npx`, `git status`, `git diff`, `git log`, `git show`, `git add`, `git mv`, `git rm`, `git commit`, `ls`, `cat`, `grep`, `find`, `head`, `tail`, `wc`, `mkdir`.
- **Denied:** `git push`, `gh`, `curl`, `wget`, and Claude's web tools beyond those below. The runner script does every push and every GitHub call itself, so the agent can't change GitHub with a token, and can't read PR comments the runner left out. These are Claude's tool rules, not a network limit: an allowed `node` or `npm` command can still reach any host (see "Known gaps").
- **Docs on the web** (the user's decision, 2026-11-19): `WebSearch`, and `WebFetch` only for these documentation sites: `docs.expo.dev`, `reactnative.dev`, `nodejs.org`, `developer.mozilla.org`, `fastify.dev`, `www.typescriptlang.org`, `docs.github.com`, `docs.npmjs.com`, `www.npmjs.com`, `sqlite.org`, `valkey.io` (as `WebFetch(domain:<site>)` rules). `app/AGENTS.md` requires the versioned Expo docs before code that touches Expo's APIs. The prompts say to look in `node_modules` first: the docs, type definitions, and READMEs of the exact installed versions. A fetch outside the list is refused, and the run log shows it, so the list can grow from what's missing.
- **Secret folders:** Claude's permission rules deny `Read` and `Edit` of `~/.config/jd-cookie-agent/**`, `~/.config/gh/**`, and `~/.ssh/**`. These rules are enforced by Claude Code, not by the OS: an allowed `node -e` can still read the files (see "Known gaps").

The permissions are in `scripts/agent-run/settings.json`, passed with `--settings` from the runner's copy in `bin/`, never from the clone, so the agent can't change them for its next try. They're reviewed like code. Tools not allowed there are refused, since `claude -p` has nobody to ask.
- **No token:** the runner starts `claude`, and `npm run check`, with `GH_TOKEN` and the credential helper's variables removed from their environment (`env -u GH_TOKEN …`).
- **The checks in a sandbox:** `npm run check` runs code the agent wrote, so the runner runs it in `bwrap` (bubblewrap): the whole file system read-only except the clone, `/tmp` (a private `tmpfs`), and the npm cache; empty folders over `~/.config/jd-cookie-agent`, `~/.config/gh`, and `~/.ssh`; its own process list (`--unshare-pid --proc /proc`); and no network. Probed 2026-11-19: reading a hidden file through another process, `/proc/<pid>/root/…`, was refused even without `--unshare-pid` ("Permission denied"), but the machine's processes were visible, which `--unshare-pid` hides. Probed 2026-11-19: inside such a sandbox, `app.pem`, `~/.config/gh/hosts.yml`, and `~/.ssh/github_test01` couldn't be read, the home folder couldn't be written, and the server's tests passed (23 of 23, Valkey's skipped). The network isn't something to turn off: Ubuntu's AppArmor profile for `bwrap` refuses every network socket inside it ("failed to open socket: Permission denied"). That's also why the agent itself can't run in `bwrap`: `claude` couldn't reach its API there (`EAI_AGAIN`).
- **No hooks on push:** after the first agent run, the runner pushes with `git -c core.hooksPath=/dev/null push`. The agent can edit `.husky/`, and a `pre-push` hook it added would otherwise run while the token is in the environment. Commit hooks still run, for the agent's commits. The claim's push, inside `scripts/ticket.sh`, comes before any agent run, on a clean `main`, so its hooks are `main`'s, which the user merged.
- **Valkey:** the agent's checks run without `VALKEY_URL`, so the Valkey tests are skipped there, as `AGENTS.md` describes. CI runs them with a Valkey service on every push, and a failure reaches the next round as a failed CI job.

The three prompts live in `scripts/agent-run/` as Markdown files (`build.md`, `fix-checks.md`, `round.md`), with placeholders the runner fills in. Each one says:
- follow `AGENTS.md` and the `next-ticket` skill
- don't push, and don't touch `server/.env` or `server/data/`
- if the design doc is wrong or something needs the user's decision, write that to `.agent/stop.md` and stop. The runner then stops for help, with `stop.md` as the reason.

### The App's token

The runner needs a token for every GitHub call and push. It makes a new one before each phase of a run ("One run", step 3). Each lasts an hour. Making one:
1. **A JWT,** made with `openssl` from the App's private key, `${XDG_CONFIG_HOME:-$HOME/.config}/jd-cookie-agent/app.pem`: header `{"alg":"RS256","typ":"JWT"}`, payload `{"iat": <now - 60>, "exp": <now + 540>, "iss": "<client id>"}`, each part base64url-encoded, signed with `openssl dgst -sha256 -sign`. The client ID is in `${XDG_CONFIG_HOME:-$HOME/.config}/jd-cookie-agent/app.env`, as `APP_CLIENT_ID=…`. It isn't secret.
2. **The installation:** `GET /repos/<owner>/<repo>/installation`, with the JWT, gives the installation's `id`.
3. **The token:** `POST /app/installations/<id>/access_tokens` with the JWT, and the body `{"repositories": ["<repo>"]}`, so the token reaches only this repo, even if the App is ever installed on more. Both calls use `curl`, with the `Authorization` header read from a file (`-H @<file>` in a private temporary directory), so the JWT and the token never appear on a command line, where `ps` shows them.

The token is handled as an opaque string: GitHub's installation tokens start `ghs_`, are about 520 characters, and contain dots (since GitHub's stateless tokens rolled out, 2026-10-02). Nothing checks its length or shape. It reaches `gh` as `GH_TOKEN`, and `git` through a credential helper that reads it from the environment, with `origin` set to `https://github.com/<owner>/<repo>.git`. It's never written to a file, a log, or a URL. If any step fails, the run logs which one, with the HTTP status, and exits 1.

Commits in the clone, the claim commit included, have the App's bot as author and committer: `jd-cookie-agent[bot]` and `358547770+jd-cookie-agent[bot]@users.noreply.github.com`, with the id read from `GET /users/jd-cookie-agent[bot]` at run time, not hard-coded. GitHub then shows the commits as the App's.

The App's permissions, on this repository only:
- **Contents:** read and write, to push branches.
- **Pull requests:** read and write, to open PRs and reply to review comments.
- **Issues:** read and write, for labels and PR comments.
- **Actions:** read, for the failed jobs' logs.
- **Checks** and **Commit statuses:** read, for `gh pr checks`.
- **Metadata:** read (always on).
- Not **Workflows**: a push that changes `.github/workflows/` is refused by GitHub. The runner then adds `needs-help` with the comment "This ticket changes a workflow, which the runner's App can't push." See "Decisions made for this ticket".

### The timer

`scripts/agent-timer.sh install` writes two units to `${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/`, runs `systemctl --user daemon-reload`, and `systemctl --user enable --now jd-cookie-agent.timer`:
- `jd-cookie-agent.service`: `Type=oneshot`, `ExecStart=<repo>/scripts/agent-run.sh`, the runner's copy in `bin/`. It sets `TimeoutStartSec=4h`, a cap on the whole run, since a run can take three 45-minute agent tries, their checks, and a round (systemd has no start timeout for `Type=oneshot` unless one is set). It writes `XDG_CONFIG_HOME`, `XDG_DATA_HOME`, and `XDG_STATE_HOME` into the unit as `Environment=`, resolved at install time, so the service uses the same folders `install` checked. It sets the `PATH` from the user's shell at install time, so `node`, `npm`, `claude`, and `gh` are found. Probed 2026-11-19: `claude -p` under `systemd-run --user`, with only `PATH` set, answered with the user's Claude login and exited 0. The service's environment has `HOME`, `USER`, `XDG_RUNTIME_DIR`, and `PATH`, but not `XDG_CONFIG_HOME`, `XDG_DATA_HOME`, or `XDG_STATE_HOME`, hence the `Environment=` lines.
- `jd-cookie-agent.timer`: `OnBootSec=5min`, `OnUnitInactiveSec=15min`, so a run starts 15 minutes after the last one ended.

The runner creates the labels `agent-run` and `needs-help` when it first needs them and they don't exist (`gh label create`, with the App's token). Neither exists in the repo today.

It checks that linger is on (`loginctl show-user "$USER" -p Linger`). If it isn't, it says to run `sudo loginctl enable-linger "$USER"`, and installs anyway. It also checks that `claude`, `gh`, `node`, `npm`, `curl`, `openssl`, `flock`, and `bwrap` are on `PATH`, that `bwrap` can hide a file and has no network (it makes a file in a temporary folder and checks it can't be read inside, and that a TCP connection to `127.0.0.1` fails inside), that `app.pem` exists and only the user can read it (mode `600`), that `app.env` sets `APP_CLIENT_ID`, and that a token can be made (the steps of "The App's token"), and stops if not. Running `install` again updates the units.

`scripts/agent-timer.sh check` runs every check above, and makes a token, without writing or starting anything. `install` runs it first.

`uninstall` disables and stops the timer, and removes both units. It leaves the clone and the logs. `status` prints `systemctl --user list-timers jd-cookie-agent.timer` and the last run's log.

### Logs

Each run writes a log to `${XDG_STATE_HOME:-$HOME/.local/state}/jd-cookie-agent/logs/<UTC time>.log`: each step it took, the commands it ran with their exit codes, and the agent's output. It keeps the last 200 logs. The journal also has each run's output: `journalctl --user -u jd-cookie-agent`.

## Security and configuration

- **Who can trigger it:** only the timer, or the user running the script. Its input is `main` (only the user merges), the runner's own branches and PRs, and comments from Qodo and the repo owner.
- **Credentials:** the App's private key, on the user's machine only, readable only by the user, never in the repo. Each run's token lasts an hour and reaches only this repo, with the permissions above. The agent never has it. The user's own `gh` login and deploy key aren't used. The agent's Claude login is the user's.
- **Pushing to `main`:** the App's contents permission would let it push to `main`, and `main` has no ruleset today (`gh api repos/<owner>/<repo>/rules/branches/main` returns `[]`). The runner never pushes to `main`: it pushes only branches it claimed. See "Tasks for the user" for the ruleset.
- **Untrusted text:** comments by other accounts are never passed to the agent. Qodo's text is passed, but the agent can only change files in its clone, and the checks and Qodo's next review see everything it changes.
- **Failure modes:**
  - GitHub can't be reached: the run logs the failed command and exits 1. The next run tries again.
  - The agent fails or times out: that counts as a failed try.
  - Two runs at once: the lock.
  - A crash mid-build: the next run finds a claim with no PR and stops for help.
- **The project's rules:**
  - Rule 1 (count before you check): the retry and round limits are counted from what's on GitHub before each try, and only one run works at a time (the lock), so no two runs count at once.
  - Rule 2 (no shared state in process memory): the runner keeps no state between runs. One runner per machine, and one ticket at a time, are out of scope for more.
  - Rule 3: `docs/devops.md` gets the runner's section in the same PR.
  - Rule 4: the runner's agent follows `next-ticket`, which leaves versions to release-please.
  - Rule 5: the new `scripts` CI job follows it. The runner itself runs outside GitHub Actions.
- **No new settings.** The interval, the limits, and the labels are constants at the top of `agent-run.sh`. For the tests only, `AGENT_RUN_ORIGIN` replaces the clone's `origin` URL (by default `https://github.com/<owner>/<repo>.git`), and `AGENT_RUN_GITHUB_API` the API's base URL. The tests set `GIT_ALLOW_PROTOCOL=file`, so no git command in them can reach GitHub.
- **Known gaps:**
  - The agent can run `npm` scripts, which can run any code in the repo, like the hooks and tests already do.
  - The time limit doesn't cap cost. `--max-budget-usd` only applies to API keys, and this uses the user's login.
  - **The agent can read the machine's credentials:** it runs as the user, so an allowed command such as `node -e` can read `app.pem`, the user's `gh` token (`~/.config/gh/hosts.yml`), and the deploy key (`~/.ssh/github_test01`, which can push to Test01), despite Claude's rules. It could then send them anywhere: an allowed `node` or `npm` command can reach any host. Only the checks and the title check, in the sandbox, have no network. What limits the damage: the App and the `gh` token reach only this repo, the ruleset keeps everyone off `main` except by a merged PR, and the user can revoke the App key or the deploy key on GitHub. Closing the gap is two backlog items (the user's decision, 2026-11-19): "Run the runner's agent as its own Linux user", then "A credential broker for the runner".
  - Anyone else with the user's account on this machine can read `app.pem` too, and act as the App on this repo. Revoking the key on the App's page stops that.

## Tasks for the user

- **Before the real run (check 13), any time before or after this PR merges:**
  1. **Create the App** `JD-cookie-Agent` (done 2026-11-19, and installed on Test01 by the user's account) (GitHub → Settings → Developer settings → GitHub Apps → New GitHub App), as for release-please's App in `docs/devops.md`: no webhook, installable only on this account, with the permissions in "The App's token". Install it on Test01 only.
  2. **Save its key and client ID** (made 2026-11-19; to be moved from the checkout to `~/.config/jd-cookie-agent/`): generate a private key, save it as `~/.config/jd-cookie-agent/app.pem` with mode `600`, and write `APP_CLIENT_ID=<client id>` to `~/.config/jd-cookie-agent/app.env`.
  3. **Qodo:** turn on "Allow GitHub bot reviews", and add release-please's App to the logins that aren't reviewed: `test01-release-please[bot]` (its login in GitHub's API), and `app/test01-release-please` (as `gh` shows it), since it's not known which form Qodo matches.
  4. **A ruleset for `main`** (Settings → Rules → Rulesets): require a pull request, and block force pushes and deletion, with no bypass. Then nobody, the App included, pushes to `main` except by merging a PR.

  The builder checks 1 and 2 with `scripts/agent-timer.sh check`, which makes a token and starts nothing, and 4 with `gh api repos/<owner>/<repo>/rules/branches/main`, which must list `pull_request`, `non_fast_forward`, and `deletion`, and `gh api repos/<owner>/<repo>/rulesets/<id>`, which must show `"enforcement": "active"` and no `bypass_actors`. If the user's token can't read `bypass_actors`, the builder asks the user to confirm "Bypass list: empty" on the ruleset's page. Step 3 shows on the first real PR: Qodo reviews it. The next release PR shows that Qodo still skips release-please.
- **After this PR merges:** run `scripts/agent-timer.sh install` on the machine. The builder can't, because it starts the timer, and the timer should run the merged `main`. Check: `scripts/agent-timer.sh status` shows the timer.
- **After that:** the real run (check 13). It happens after this PR merges, so its results go in a follow-up docs PR to this feature's "Delivery and review", as ticket 003's last checks did in PR #12.
- **Already done on this machine (2026-11-18):** linger is on.

## Implementation map

- `scripts/agent-run.sh` (new): one run, as in "Processing".
- `scripts/agent-run/build.md`, `fix-checks.md`, `round.md` (new): the agent's prompts.
- `scripts/agent-run/settings.json` (new): the agent's Claude permissions ("The agent").
- `scripts/agent-timer.sh` (new): `install`, `uninstall`, `status`.
- `scripts/agent-token.sh` (new): makes the App's token ("The App's token"), and prints it only to a file descriptor the runner reads. Used by `agent-run.sh` and `agent-timer.sh install`.
- `scripts/test/agent-run.test.sh` (new): the tests below. Run by a new `npm run test:scripts` at the root. The root `check` runs it after the server's and the app's checks.
- `.github/workflows/ci.yml`: a third job, `scripts`, that runs `npm run test:scripts` on `ubuntu-24.04`, following rule 5 like the other two. CI doesn't run the root `check` today: its jobs run the server's and the app's.
- `.husky/pre-commit`: also runs `npm run test:scripts` when `scripts/` has staged changes.
- `.gitignore`: `.agent/`, and `*.pem`, which the user added in their checkout on 2026-11-19, so no App key in a working tree is committed.
- `docs/devops.md`: a section on the runner: what it does, installing, following a run, and stopping it.
- `AGENTS.md`: a line in the table for the runner.

## Acceptance checks

Checks 1 to 12 are in `scripts/test/agent-run.test.sh`. It runs the runner against a scratch setup: a local bare repo as `origin`, holding a copy of the backlog with one `ready` ticket; stub `gh`, `claude`, and `curl` commands first on `PATH` (the `curl` stub answers the two token calls with a fake token of 520 characters, `ghs_` and two dots, as GitHub's are; the `gh` fixtures for Qodo's comments are copies of real ones from PRs #10 and #12, which start with a blank line or `<h3>`), which record how they were called and answer from fixture files, with lists long enough to need a second page, and the deciding comment or event on the last one; and `npm run check` replaced by a stub that passes, fails, or hangs on cue. `AGENT_RUN_ORIGIN` points the clone at the bare repo. Each check passes when the script prints `ok N`, and CI runs it.

1. **No ticket:** with no `ready` ticket, a run claims nothing, calls `claude` 0 times, and logs `no ready ticket`.
2. **Build:** with one `ready` ticket, a run creates its claim branch on the bare `origin`, calls `claude` once with the build prompt, runs the check stub once, pushes the branch, and calls `gh pr create` with the label `agent-run` and the title from `.agent/pr.md`.
3. **Check retries:** with the check stub failing every time, the run calls `claude` 3 times in all, then opens a draft PR with `needs-help`. The run folder has `commits.patch` and `uncommitted.patch`: with the agent stub leaving one new untracked file and one changed binary file, applying both to a fresh clone of the bare `origin` (`git am`, then `git apply`) gives the clone's tree exactly. With the check stub hanging, the try fails after the time limit (shortened by the test), and the next try runs. With it failing once, then passing, it opens a normal PR after 2 tries. With a `pr.md` title that commitlint rejects, the title counts as a failed check, and `gh pr create` is never called with it. With the agent stub replacing `commitlint.config.mjs` in the clone by one that writes a file when loaded, the title check uses `main`'s config, and the file isn't written outside the sandbox.
   - **Stops before a PR:** with the agent stub writing `.agent/stop.md`, the run opens a draft PR with `needs-help` and `stop.md` as the comment. With the `gh`/push stub refusing a push that changes `.github/workflows/`, it opens the draft PR from the branch as it is on `origin`, and the comment names the patch files.
   - **Bad agent output:** with `.agent/pr.md` left over from an earlier try and the agent stub writing nothing, the try fails. With `replies.json` not valid JSON, naming a comment id that wasn't collected, naming one twice, or leaving one out, the try fails.
4. **Waits for Qodo and CI:** with an open `agent-run` PR whose Qodo review comment names an older commit, a run calls `claude` 0 times and changes nothing. The same with Qodo done and a CI check pending, and with Qodo done and no checks listed at all. With Qodo's "PR Summary" comment naming the head and its review comment an older commit, it still waits. With the push 61 minutes ago, it adds `needs-help`.
5. **Round:** with Qodo's review comment (`Code Review by Qodo`) for the head commit and one new Qodo inline comment, a run calls `claude` once with the round prompt, which contains that comment's text. It posts `Agent round 1 started` before calling `claude`, posts `Agent round 1` with `pushed` naming the new commit, then pushes, then posts the reply from `replies.json` to that comment's id. With a failed CI job, its failed log lines are in the round prompt. With an owner's review body (a review with no inline comment), its text is in the prompt.
6. **Only Qodo and the owner:** a comment from another account, containing `IGNORE-ME`, is not in the round prompt. One from the owner is, both inline and on the PR itself. A comment by `jd-cookie-agent[bot]`, containing `MINE`, is not.
7. **Round limit and crashes in a round:** with 4 `Agent round N started` comments since the PR opened, a run adds `needs-help` and calls `claude` 0 times, also when some of the 4 have no `Agent round N` after them. With `needs-help` removed after round 4, and nothing else new, the next run runs round 5 as a new round 1.
   - With `Agent round 1 started` and no `Agent round 1` (a crash during the agent), the next run runs round 2 on the same head, and calls `claude` once.
   - With `Agent round 1` posted, its `pushed` commit in the clone but not on `origin` (a crash before the push), the next run pushes it, and calls `claude` 0 times. With that commit in neither, it adds `needs-help`.
   - With `Agent round 1` posted and pushed but its reply not, the next run posts the reply, and calls `claude` 0 times for it.
   - With an owner comment dated after the round's `cutoff` but before its `Agent round 1` comment, the next run runs a round with it.
   - With an owner comment from before the cutoff, edited after it, and no new commit, the next run runs a round with it.
   - With a round on commit A that pushed commit B, and Qodo's comment edited to name B, the next run runs a round on B.
8. **Done:** with the review comment for the head commit, no round on that head yet, CI green, and the agent stub changing nothing, a run calls `claude` once, posts `Agent round N`, and comments `Ready for review by the user.`, in that same run. A second run calls `claude` 0 times and doesn't comment again.
   - **CI stays red:** with a failed CI job and the agent stub changing nothing, the run adds `needs-help` with "CI still fails, and round N changed nothing." and doesn't post `Ready for review by the user.`
   - **Main moved on:** after `Ready for review by the user.`, with `main` on the bare `origin` one commit ahead of the PR's branch, the next run runs a round, and its push holds a merge of `main`.
   - **A draft PR after `needs-help`:** with `needs-help` removed from a draft PR and the round pushing nothing, the run marks the PR ready for review before it posts `Ready for review by the user.`
   - **A conflict with main:** with a conflicting commit on `main`, the run adds `needs-help` and calls `claude` 0 times.
   - **A workflow change in a round:** with the push stub refusing the round's push, the run adds `needs-help`, and the run folder has the patches.
9. **Crash, lock, and `needs-help`:**
   - a claim branch with no PR gets a draft PR with `needs-help`, and no `claude` call
   - a claim branch whose PR was merged, and one whose PR was closed, get no PR and no `claude` call, and the run goes on to `ticket.sh list`
   - a claim branch with another agent's name in its `Claimed-By` trailer is never touched. The agent name is `runner-` and the first 12 characters of the machine id (a stub `/etc/machine-id` path in the test)
   - a second run while the first holds the lock exits 0 at once
   - a PR with `needs-help` gets no `claude` call
10. **The token:** with a test key made by `openssl genrsa` and the `curl` stub:
    - the JWT the stub receives verifies with the key's public half (`openssl dgst -sha256 -verify`), its `iss` is the client ID, and `exp - iat` is 600
    - the fake 520-character token reaches the `gh` stub as `GH_TOKEN`
    - the credential helper, asked by `git credential fill` for `https://github.com`, answers `username=x-access-token` and the token. (A push to a local bare `origin` never asks a credential helper. Probed 2026-11-19, so the helper is tested on its own.)
    - with the clock moved past the hour between two agent tries (a stub `date`), the `curl` stub sees a second token request before the push
    - the token's text appears in no log file, and in no command line the stubs record, `claude`'s included, and `claude`'s environment has no `GH_TOKEN`
    - with the stub answering `401`, the run logs the failed step and exits 1, with no `claude` call
    - with `app.pem` readable by others (mode `644`), `agent-timer.sh check` and `install` stop, and `check` writes no unit
11. **The agent's limits:** with the `claude` stub recording its arguments and environment, and a `bwrap` stub recording its own:
    - `claude` gets `--settings` with the runner's copy in `bin/`, not the clone's: with the agent stub rewriting the clone's `scripts/agent-run/settings.json` in try 1, try 2 gets the same settings as try 1. That file allows `WebSearch` and exactly the listed `WebFetch` domains, and denies `Read` and `Edit` of the three secret folders
    - `npm run check` and the title check run only through `bwrap`, with `--ro-bind / /`, the clone bound writable, `--tmpfs` over the three secret folders and `/tmp`, `--unshare-pid --proc /proc`, and no `GH_TOKEN` in their environment
    - every push has `core.hooksPath=/dev/null`: a `pre-push` hook in the clone's `.husky/` that writes a file doesn't run
    - with a real `bwrap`, when the machine has one (skipped in CI if it doesn't), a check stub that tries to read a file under a fake secret folder fails to read it, and one that opens a TCP connection to `127.0.0.1` fails. `agent-timer.sh check` makes the same two tries, and stops if either succeeds: the sandbox's lack of network comes from AppArmor, so a machine without that profile must not pass
12. **Timer units:** `scripts/agent-timer.sh install`, with the three XDG folders set to scratch directories and stubs for `systemctl`, `loginctl`, and `gh`, writes both units and the copy in `bin/`. The service has `TimeoutStartSec=4h`, `ExecStart` in `bin/`, and `Environment=` lines with those three folders. `systemd-analyze verify` on the two files exits 0 and prints no line that names either file. `uninstall` removes them. In `agent-run.test.sh`. Probed 2026-11-19 (systemd 259): `verify` exits 0 even for an unknown key, and only prints a warning, hence the check on its output. `--user verify` fails with no login session, as in CI, while plain `verify` works. A missing `ExecStart` program makes it exit 1.
13. **The real run** (Day 4 of the hackathon, with the user): with the timer installed and one small ticket `ready` ("Delete expired session rows"), the runner claims it, builds it, opens a PR that Qodo reviews, and runs rounds until it reports `Ready for review by the user.` or stops with `needs-help`. Shown by the PR, its comments, and the runner's logs. Record what happened in this doc's "Delivery and review", in a follow-up docs PR (see "Tasks for the user"): who opened the PR (`jd-cookie-agent[bot]`), the checks, Qodo's findings, the rounds and retries, and where the user had to step in.
14. `npm run check` passes locally and in CI, and `docs/devops.md` has the runner's section.

## Readiness review

Refined 2026-11-19 by Claude Code (claude-opus-5-5).

- **Goal, restated:** for the user, who wants ready tickets built without starting a session for each. A script, started every 15 minutes by a systemd user timer, does one step per run: claim and build a ready ticket, get the checks green, open the PR, then run a fix round on each Qodo review, up to set limits, and stop with `needs-help` when stuck. The user still marks tickets ready and merges.
- **Is it needed:** not built: `scripts/` has only `ticket.sh`, and no timer or runner is in the repo or the docs. Overlaps: "Code reviews by our own agents" is a separate row, out of scope here. No open PRs. Never dropped: the backlog history has no runner or scheduled build.
- **Facts checked while refining:**
  - `scripts/ticket.sh claim` pushes the claim branch itself, with a `Claimed-By:` trailer, and has exit code 5 for a ticket withdrawn during the claim. Added to the build step.
  - The runner posted as the user, so its own round comments and replies would have come back to the agent as the owner's comments. Fixed by the user's choice of a GitHub App (Q1), with the runner's comments told apart by author. Also added: the owner's PR comments, which the doc had left out, and a marker naming the head commit of each round.
  - `main` has no ruleset (`gh api repos/JD-cookie/Test01/rules/branches/main` returns `[]`), so the App's contents permission could push to it.
  - GitHub's App installation tokens are about 520 characters, with dots, since 2026-10-02. The runner treats the token as opaque, and check 10 uses a fake token of that shape.
  - `next-ticket` step 4 merges `main` into the branch during review. Added as review step 5.
  - The labels `agent-run` and `needs-help` don't exist in the repo yet.
  - `gh pr edit` fails in `gh` 2.46, so labels are changed with `gh api`.
  - CI doesn't run the root `check`. Added: a `scripts` CI job and the pre-commit hook.
  - `systemd-analyze` (probed): `--user verify` fails without a login session, and `verify` exits 0 on unknown keys. Check 10 rewritten.
  - The `gh` token expires 2027-01-11: a known gap.

- **Definition of Ready:**
  1. pass: the Summary says who it's for, what changes, and what doesn't
  2. pass: see "Is it needed"
  3. pass: an out-of-scope list; reviews by our own agents are their own row
  4. pass, the largest ticket yet: scripts, one CI job, and docs. The timer alone or the runner alone wouldn't deliver a run on a schedule, so it stays one ticket
  5. pass: every label, comment text, file path, exit code, and App permission is given
  6. pass: the App, its key, Qodo's settings, the ruleset, and installing the timer, each with when and how the builder checks it
  7. pass: checks 1 to 12 run against stubs and a bare `origin`, with `ok N` as the result; check 13 is the real run
  8. pass: each rule, in "Security and configuration"
  9. pass: who triggers it, the failure modes, the token's handling, the known gaps
  10. pass: Q1 to Q5 answered, below
- **Questions and answers:**
  - Q1: the runner's own GitHub identity, as a GitHub App → yes (2026-11-19). The user made `JD-cookie-Agent` and turns on Qodo's bot reviews, skipping release-please by login.
  - Q2: one agent round on every commit Qodo reviews, even with no findings → yes.
  - Q3: probe `claude -p` under `systemd-run --user` → yes: it worked (see "The timer").
  - Q4: no Workflows permission for the App, and `needs-help` for a ticket that changes a workflow → yes.
  - Q5: a ruleset on `main` (a PR required, no force pushes or deletion, no bypass) → yes, a task for the user.
  - Q6: keep the App key from the agent → the user asked how; a probe showed `claude` can't run in `bwrap` here (AppArmor blocks its network). Options: (A) the agent as its own Linux user, (B) Claude's permission rules plus the checks in `bwrap`, or a credential broker, which the user suggested. → B now, with backlog rows for A and the broker (2026-11-19).
  - Q7: web access for docs → `WebSearch`, and `WebFetch` only for documentation sites, `node_modules` first (2026-11-19).
  - Q8: round 2's reviewers, after a tie (14 kept each) → both again.
  - Naming: the runner's local folders, units, lock, and marker → `jd-cookie-agent`, like the App (the user's request, 2026-11-19).
- **Probes:** `systemd-analyze verify` (see check 12); `bwrap` hiding files, blocking the network, and running the server's tests (see "The agent"); `claude -p` in a systemd user service (see "The timer").
- **Review round 1:** Codex (gpt-6.1-sol) and opencode (ollama-cloud/kimi-k3.1-pro), run separately. Both restatements match the goal. They made 28 findings, 14 each. 7 problems were found by both, so 21 in all. All were kept: 19 fixed in the doc, 2 turned into questions (Q6, Q7).
  - Both: a merged or closed PR looked like a crashed build (only open PRs were listed). Fixed: PRs in every state, by branch.
  - Both: one token at the start of a run could expire before its last push (3 tries × 45 minutes). Fixed: a token per phase, with a test.
  - Both: a round was counted only after it finished, so a crash mid-round was never counted, against rule 1. Fixed: `Agent round N started` is posted first, and counted.
  - Both: stopping before a PR exists (`stop.md`, a refused workflow push) had no PR to label. Fixed: "Stopping before a PR exists", with the work saved as patches.
  - Both: the agent, running as the user, could read `app.pem` with its allowed `cat` and `node`. Asked the user (Q6). Fixed meanwhile: `npm run check` gets no token either.
  - Both (needs a run): a push to a local bare `origin` never asks a credential helper. Probed: `helper NOT called`. Fixed: the helper is tested with `git credential fill`.
  - Both: removing `needs-help`, or `main` moving on, didn't start a round, because "nothing to do" came first. Fixed: both are reasons for a round.
  - Codex: a round's marker named the pushed commit, so its results could be taken for a review of the new one. Fixed: `reviewed` and `pushed` are separate.
  - Codex: comments posted while the agent worked fell before the next cutoff and were skipped. Fixed: the cutoff is the collection time.
  - Codex: a run dying between the round comment and its replies left replies unposted forever. Fixed: the replies are in the round's marker, and the next run posts any missing.
  - Codex: a draft PR stayed a draft after `needs-help` was removed. Fixed: the runner marks it ready.
  - Codex: the builder was told both to run `install` and not to. Fixed: `agent-timer.sh check`.
  - Codex: a wrong PR title could never be fixed, since only the runner talks to GitHub. Fixed: commitlint before `gh pr create`, and a round can change the title.
  - Codex: Expo tickets must fetch versioned docs (`app/AGENTS.md`), and web tools were denied. Asked the user (Q7).
  - opencode: two machines would both work every `agent-run` PR. Fixed: a runner works only on its own claims.
  - opencode: stale or invalid `.agent/` files could pass. Fixed: "The agent's files".
  - opencode: no check covered pending or failed CI. Fixed: in checks 4 and 5.
  - opencode: an owner's review body, with no inline comment, was left out. Fixed: review bodies are collected.
  - opencode: the agent can't run the Valkey tests. Fixed: the doc says CI runs them, and a failure comes back as a failed job.
  - opencode: the real run comes after the merge, but "Delivery and review" is filled before. Fixed: a follow-up docs PR, as for ticket 003. Also a wrong check number.
  - opencode (needs a run): Qodo's comment may not start with "Code Review by Qodo". Probed: it starts with a blank line or `<h3>`, and the "PR Summary by Qodo" comment names the same commit. Fixed: the heading is matched anywhere, and the fixtures are real comments.
  - Dropped: 0.
  - Kept for later rounds: asked the user (Q8), since both had 14 kept.
- **Review round 2:** Codex (gpt-6.1-sol) and opencode (ollama-cloud/kimi-k3.1-pro), both at the user's choice after a tie. Both restatements match. 29 findings (Codex 14, opencode 15), 6 found by both, so 23 problems. 28 kept, all fixed in the doc, and 1 dropped.
  - Both: an `Agent round N started` record already named the head, so a crash during the agent marked the head as done. Fixed: only a finished round marks it.
  - Both: a crash after the push but before the report lost the report and the replies. Fixed: the report is posted before the push, with `pushed`, and the next run finishes the push or the replies.
  - Both: the saved patches missed untracked and binary files, and the run's folder wasn't defined. Fixed: `--binary` patches with `git add -A`, a `runs/<time>/` folder, and a test that restores them.
  - Both: stopping during review (`stop.md`, a refused push) had no defined path. Fixed: one "Stopping for help" for both phases.
  - Both: red CI after a round that changed nothing, or no checks at all, left the PR waiting forever. Fixed: `needs-help`, and no checks means CI hasn't started.
  - Both: `npm run check` had no time limit, and the service no overall one. Fixed: 20 minutes per check, `TimeoutStartSec=4h`.
  - Codex: `ticket.sh`'s claim push runs hooks. Answered in the doc: it runs before any agent run, on `main`'s hooks.
  - Codex: a comment edited after the cutoff was missed. Fixed: `updated_at`.
  - Codex: `install` and the service could use different XDG folders. Fixed: resolved into the unit.
  - Codex: the tests' local `origin` conflicted with the GitHub URL. Fixed: `AGENT_RUN_ORIGIN` for tests, and `GIT_ALLOW_PROTOCOL=file`.
  - Codex: check 5's fixture could be the "PR Summary" comment, and check 8 wanted "Ready" in the same run the steps exited. Fixed both.
  - Codex: `replies.json` could leave comments out or repeat them. Fixed: exactly one each.
  - opencode: the no-PR recovery both pushed and didn't. Fixed: one procedure, which a later run can finish.
  - opencode: short host names aren't unique. Fixed: the machine id.
  - opencode: no list read was paginated. Fixed: `--paginate`, with multi-page fixtures.
  - opencode: nothing checks that the sandbox has no network. Fixed: in check 11 and `agent-timer.sh check`.
  - opencode: "denied web access" overstated it: `node` and `npm` reach any host. Fixed: the claim, and the known gap.
  - opencode: the agent could edit `settings.json` for its next try. Fixed: the runner's scripts, prompts, and settings are a copy in `bin/`, made by `install`.
  - opencode: commitlint ran the branch's JavaScript config next to the token. Fixed: `main`'s config, in the sandbox.
  - opencode: listing the branch's rules doesn't show the ruleset's bypass list. Fixed: read the ruleset too.
  - Dropped: 1. Codex 6 (needs a run): a hidden file could be read through `/proc/<pid>/root`. Probed: "Permission denied". The probe did show the machine's processes, so the sandbox adds `--unshare-pid`.

## Decisions made for this ticket

Decided by the user on 2026-11-18:
- **A systemd user timer on the user's machine, installed by a script,** so a new machine is set up with one command. Not GitHub Actions: it would need a Claude API key as a secret in a public repo, and it couldn't use the user's Claude login. Not T3 Code's scheduled tasks: nothing would be in the repo to review or reuse.
- **One step per run, with the state in GitHub.** A reboot or a crash loses nothing, and every run leaves a log.
- **Retry limits:** 3 tries to get the checks green, 4 Qodo rounds. Then `needs-help`, and the runner waits for the user.
- **Only Qodo's and the repo owner's comments reach the agent,** because anyone can comment on a public repo.
- **The runner is a GitHub App, `JD-cookie-Agent`** (2026-11-19). Its PRs and comments are its own, so the user gets notified and can review them, and its tokens last an hour and reach only this repo. A second "machine user" account was the other option: Qodo would review it with no change, but its token may not be limited to one repo. With the App, the user turns on Qodo's bot reviews and skips release-please by its login.
- **Claude Code (`claude -p`) in its own clone.** It never merges, never pushes (the runner does), and never touches `server/.env` or the development database.
- **One ticket at a time, and the user starts the timer.**
- **One agent round on every commit Qodo reviews** (2026-11-19), even when Qodo finds nothing. Qodo's summary has no fixed "all clear" form, so the agent decides what's open. The cost is one short `claude` run before `Ready for review by the user.`
- **No Workflows permission for the App** (2026-11-19). A PR built by the runner can't change CI, the most sensitive files in a public repo (rule 5). A ticket that changes a workflow stops with `needs-help`, and the user finishes it.
- **A ruleset on `main`** (2026-11-19): a pull request is required, and force pushes and deletion are blocked, with no bypass. The App's contents permission would otherwise let it push to `main`. The user sets it up (see "Tasks for the user").
- **Keeping credentials from the agent, for now** (2026-11-19): Claude's permission rules deny the secret folders, the checks run in `bwrap` with no network, the token is never in the agent's or the checks' environment, and pushes run no hooks. The agent can still read the files with an allowed command: a known gap. The other options, both for later backlog items: the agent as its own Linux user (the OS hides every credential, but it needs `sudo` once and a `claude login` as that user), and a credential broker, a small service as another user that holds the key and does only the runner's actions (it hides the App key, but not the user's `gh` token or deploy key, and it's the most new code). `claude` can't run in `bwrap` on this machine, so the sandbox can't hold the agent itself.
- **Docs on the web** (2026-11-19): `WebSearch`, and `WebFetch` for the documentation sites in "The agent". Agents need API docs while building, and `app/AGENTS.md` requires Expo's. An open `WebFetch` would add any site's text as input, and with the known gap above, a way to send a credential out.
- **No notifications outside GitHub** (2026-11-18): GitHub's own are enough now that the runner is the App. A push service such as ntfy was the other option, but it's an outside service.
