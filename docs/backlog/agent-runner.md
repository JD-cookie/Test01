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
- More than one ticket at a time, or more than one runner per machine.
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
- **The runner's marker:** every comment and reply the runner posts ends with `<!-- test01-agent head=<sha> -->`, naming the PR's head commit when it posted. That's how the runner knows which commit it already ran a round on.
- **The App:** `JD-cookie-Agent`, a GitHub App installed only on this repo, made by the user on 2026-11-19. GitHub derives its bot user from the name, in lower case: `jd-cookie-agent[bot]`, user id 358547770 (`gh api 'users/jd-cookie-agent[bot]'`). The runner's files and units keep the name `test01-agent`. It's the runner's identity on GitHub: its PRs, comments, labels, and pushes come from `jd-cookie-agent[bot]`, not from the user.

## User-facing behavior

For the user:
1. Install and start the timer once per machine: `scripts/agent-timer.sh install`. `scripts/agent-timer.sh status` shows the timer and the last run's log. `scripts/agent-timer.sh uninstall` stops it and removes it.
2. Mark a ticket `ready` as usual. Within 15 minutes, the runner claims it.
3. Follow it on GitHub: its PR carries the label `agent-run`. Each round adds a comment from the runner that starts `Agent round N`. When it's done, it comments `Ready for review by the user.`
4. If it stops for help, the PR gets the label `needs-help` and a comment that says why. To let it go on, fix what's needed, then remove the label. Removing it resets the retry counts.
5. Merge, or close the PR, as for any PR.

The runner pushes, opens PRs, and comments as the App `jd-cookie-agent[bot]` (see "The App's token"). So the user gets GitHub's notifications for them, and can review its PRs like anyone else's. Qodo reviews them once the user has turned on bot reviews in Qodo, with release-please's App on Qodo's skip list (see "Tasks for the user"): Qodo didn't review release-please's PR #4, because bot reviews were off.

## Processing

### One run

`scripts/agent-run.sh` takes no arguments. It works in its own clone, `${XDG_DATA_HOME:-$HOME/.local/share}/test01-agent/repo`, and never in the user's checkout. It clones `origin` there if that clone doesn't exist. Its agent name for claims is `runner-$(hostname -s)`.

1. **Lock.** It takes `flock -n` on `${XDG_RUNTIME_DIR}/test01-agent.lock`. If another run holds it, it exits 0. systemd doesn't start a service that's still running, either. The lock also covers runs started by hand.
2. **Find its work.** It lists open PRs with the label `agent-run` (`gh pr list --label agent-run --state open`), and branches on `origin` whose claim commit names its agent name.
   - **A PR with `needs-help`:** nothing to do. Exit.
   - **A PR without it:** review step (below).
   - **A claimed branch with no PR:** an earlier run died while building, for example in a reboot. Push nothing new. Open a draft PR from the branch with the labels `agent-run` and `needs-help`, and the comment "A run stopped while building this ticket. Its work so far is on this branch." Exit.
   - **None of these:** if `scripts/ticket.sh list` shows a free `ready` ticket, build step (below). If not, log `no ready ticket` and exit.

   Only one ticket is in progress at a time: the runner doesn't start a new one while any of its PRs is open, `needs-help` or not.

### Build step

1. In the clone: `git fetch`, then switch to a clean `main` at `origin/main`, and delete every other local branch: the clone is the runner's own, and what matters is on `origin`. A local branch left by a run that failed would make the next claim fail. Then `npm ci` at the root and in `server/` and `app/`, so the hooks and checks run as in CI.
2. `scripts/ticket.sh claim next "runner-$(hostname -s)"`. Its exit codes (see `scripts/ticket.sh`):
   - **0:** claimed. The script has already pushed the claim branch, `NNN-slug`, whose commit has the trailer `Claimed-By: runner-<host>`. That trailer is how step 2 of "One run" finds the runner's branches.
   - **3:** no free ticket. Exit 0.
   - **5:** claimed, but the ticket was withdrawn or changed on `main` meanwhile. Open a draft PR from the branch with `agent-run` and `needs-help`, and the script's message as the comment. Exit.
   - **anything else (2, 4):** log the message and exit 1. If the claim reached `origin` after all, the next run finds a claimed branch with no PR, and stops for help.
3. **Build**, try 1 of 3: run the agent with the build prompt (see "The agent"). It follows the `next-ticket` skill's step 2, and commits, but doesn't push.
4. **Checks:** the runner itself runs `npm run check` in the clone. It doesn't take the agent's word for it.
   - **Pass:** go to 5.
   - **Fail:** run the agent again with the fix prompt and the check's output (the last 200 lines), then check again. That's try 2, then try 3.
   - **Still failing after 3 tries:** push the branch, open a draft PR with the labels `agent-run` and `needs-help`, and comment "The checks still fail after 3 tries." with the last 200 lines of output. Exit.
5. **Push and open the PR:** push the branch, then `gh pr create --label agent-run` with the title and body the agent wrote to `.agent/pr.md` in the clone: the first line is the title, the rest is the body, as `next-ticket` step 3 describes. `.agent/` is git-ignored. Labels are added and removed later with `gh api` (`repos/<owner>/<repo>/issues/<n>/labels`), because `gh pr edit` fails in the installed `gh` 2.46.

### Review step

For the open PR without `needs-help`. The **last round** is the newest PR comment by `jd-cookie-agent[bot]` that starts `Agent round`.

1. **Wait for the review.** Qodo is done with the head commit when its summary comment, the issue comment by `qodo-code-review[bot]` that starts "Code Review by Qodo", contains `<!-- https://github.com/<owner>/<repo>/commit/<head sha> -->`. CI is done when `gh pr checks` has no pending check.
   - **Either isn't done:** exit, and check again next run.
   - **Still not done 60 minutes after the head commit was pushed:** add `needs-help`, with the comment "Qodo or CI hasn't finished reviewing <sha> after 60 minutes." Exit. The push time is the time of the runner's own comment for that head (it comments right after each push), or the PR's creation time for the first head.
2. **Collect what's new since the last round,** for the round prompt:
   - Qodo's whole summary comment: some findings are only there.
   - Comments by `qodo-code-review[bot]` and by the repo owner (`gh api repos/<owner>/<repo> --jq .owner.login`) posted after the last round, or since the PR opened: inline review comments, and the PR's own comments. The runner's own comments, by `jd-cookie-agent[bot]`, are left out.
   - For each failed CI job, its failed log lines (`gh run view <id> --log-failed`, the last 200 lines).

   Comments from anyone else are left out: the repo is public, so anyone can comment, and the agent would read their text as instructions.
3. **Is a round needed?** A round runs if no round has run on the head commit yet (the last round's marker names another commit, or there is none), or if step 2 found a new comment. Otherwise there's nothing to do: exit.

   So every head commit Qodo reviews gets one round, even when Qodo found nothing. The agent decides what's open, from the summary and the comments. It can't be read reliably from the summary alone: on PR #12, with no findings, the summary starts with counts (`🐞 Bugs (0)`, `📘 Rule violations (0)`, `📎 Requirement gaps (0)`). On PR #10, after every finding was fixed, it had no counts, only a "Resolved findings" list, each finding marked `✓ Resolved`.
4. **Count rounds.** Count the `Agent round` comments by `jd-cookie-agent[bot]` since the last time `needs-help` was removed from the PR (the PR's timeline, event `unlabeled`), or since the PR opened. If 4 rounds are done, add `needs-help`, with the comment "Qodo still has findings after 4 rounds." Exit.
5. **Catch up with `main`:** switch the clone to the PR's branch at `origin`, and `git merge origin/main`, as `next-ticket` step 4 says (no rebase, so no force-push). If the merge has a conflict, `git merge --abort`, add `needs-help`, and comment "Merging main has a conflict." Exit.
6. **Run a round:** run the agent with the round prompt and the collected text. It writes `.agent/round.md`, with each finding, whether it's confirmed, and what it did: fixed (with the commit) or answered (with the reason). It also writes `.agent/replies.json`, with one reply per inline comment: `[{"comment_id": 123, "body": "…"}]`. It updates the design doc's "Delivery and review" section, as `next-ticket` step 4 asks.
7. **Checks** as in the build step, 3 tries. If they still fail: push, add `needs-help`, and comment with the output. Exit.
8. **Push, then report:** if the round or the merge made a commit, push. Then comment `Agent round N` with the contents of `round.md`, and post each reply in `replies.json` as a reply to its comment (`gh api …/pulls/<n>/comments/<id>/replies`), each with the runner's marker for the new head. Exit. The next run waits for Qodo's review of the new head.

A round that pushed nothing, with CI green, is the last: the runner also comments `Ready for review by the user.`, with the marker. It posts that once per head commit. If the user or Qodo comments again, the next run runs a round for it.

### The agent

Each run of the agent is a fresh `claude -p` process in the clone, with no MCP servers (`--strict-mcp-config`), a time limit of 45 minutes (`timeout 45m`), and its output saved to the run's log. Its permissions:
- **Allowed:** reading files, editing files in the clone, and these shell commands: `npm`, `node`, `npx`, `git status`, `git diff`, `git log`, `git show`, `git add`, `git mv`, `git rm`, `git commit`, `ls`, `cat`, `grep`, `find`, `head`, `tail`, `wc`, `mkdir`.
- **Denied:** `git push`, `gh`, `curl`, `wget`, and web tools. The runner script does every push and every GitHub call itself, so the agent can't change GitHub, and can't read PR comments the runner left out.
- **No token:** the runner starts `claude` with `GH_TOKEN` and the credential helper's variables removed from its environment (`env -u GH_TOKEN …`), so the agent never has the App's token, even in a command it's allowed to run.

The three prompts live in `scripts/agent-run/` as Markdown files (`build.md`, `fix-checks.md`, `round.md`), with placeholders the runner fills in. Each one says:
- follow `AGENTS.md` and the `next-ticket` skill
- don't push, and don't touch `server/.env` or `server/data/`
- if the design doc is wrong or something needs the user's decision, write that to `.agent/stop.md` and stop. The runner then adds `needs-help`, with `stop.md` as the comment.

### The App's token

The runner needs a token for every GitHub call and push. It makes a new one at the start of each run, which GitHub lets live for an hour, longer than any run:
1. **A JWT,** made with `openssl` from the App's private key, `${XDG_CONFIG_HOME:-$HOME/.config}/test01-agent/app.pem`: header `{"alg":"RS256","typ":"JWT"}`, payload `{"iat": <now - 60>, "exp": <now + 540>, "iss": "<client id>"}`, each part base64url-encoded, signed with `openssl dgst -sha256 -sign`. The client ID is in `${XDG_CONFIG_HOME:-$HOME/.config}/test01-agent/app.env`, as `APP_CLIENT_ID=…`. It isn't secret.
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

`scripts/agent-timer.sh install` writes two units to `${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/`, runs `systemctl --user daemon-reload`, and `systemctl --user enable --now test01-agent.timer`:
- `test01-agent.service`: `Type=oneshot`, `ExecStart=<repo>/scripts/agent-run.sh`, where `<repo>` is the checkout `install` runs from. It sets the `PATH` from the user's shell at install time, so `node`, `npm`, `claude`, and `gh` are found. Probed 2026-11-19: `claude -p` under `systemd-run --user`, with only `PATH` set, answered with the user's Claude login and exited 0. The service's environment has `HOME`, `USER`, `XDG_RUNTIME_DIR`, and `PATH`, but not `XDG_CONFIG_HOME`, `XDG_DATA_HOME`, or `XDG_STATE_HOME`, so the scripts use their defaults (`~/.config`, `~/.local/share`, `~/.local/state`).
- `test01-agent.timer`: `OnBootSec=5min`, `OnUnitInactiveSec=15min`, so a run starts 15 minutes after the last one ended.

The runner creates the labels `agent-run` and `needs-help` when it first needs them and they don't exist (`gh label create`, with the App's token). Neither exists in the repo today.

It checks that linger is on (`loginctl show-user "$USER" -p Linger`). If it isn't, it says to run `sudo loginctl enable-linger "$USER"`, and installs anyway. It also checks that `claude`, `gh`, `node`, `npm`, `curl`, `openssl`, and `flock` are on `PATH`, that `app.pem` exists and only the user can read it (mode `600`), that `app.env` sets `APP_CLIENT_ID`, and that a token can be made (the steps of "The App's token"), and stops if not. Running `install` again updates the units.

`uninstall` disables and stops the timer, and removes both units. It leaves the clone and the logs. `status` prints `systemctl --user list-timers test01-agent.timer` and the last run's log.

### Logs

Each run writes a log to `${XDG_STATE_HOME:-$HOME/.local/state}/test01-agent/logs/<UTC time>.log`: each step it took, the commands it ran with their exit codes, and the agent's output. It keeps the last 200 logs. The journal also has each run's output: `journalctl --user -u test01-agent`.

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
- **No new settings.** The interval, the limits, and the labels are constants at the top of `agent-run.sh`.
- **Known gaps:**
  - The agent can run `npm` scripts, which can run any code in the repo, like the hooks and tests already do.
  - The time limit doesn't cap cost. `--max-budget-usd` only applies to API keys, and this uses the user's login.
  - Anyone with the user's account on this machine can read `app.pem`, and with it act as the App on this repo. Revoking the key on the App's page stops that.

## Tasks for the user

- **Before the real run (check 11), any time before or after this PR merges:**
  1. **Create the App** `JD-cookie-Agent` (done 2026-11-19, and installed on Test01 by the user's account) (GitHub → Settings → Developer settings → GitHub Apps → New GitHub App), as for release-please's App in `docs/devops.md`: no webhook, installable only on this account, with the permissions in "The App's token". Install it on Test01 only.
  2. **Save its key and client ID** (made 2026-11-19; to be moved from the checkout to `~/.config/test01-agent/`): generate a private key, save it as `~/.config/test01-agent/app.pem` with mode `600`, and write `APP_CLIENT_ID=<client id>` to `~/.config/test01-agent/app.env`.
  3. **Qodo:** turn on "Allow GitHub bot reviews", and add release-please's App to the logins that aren't reviewed: `test01-release-please[bot]` (its login in GitHub's API), and `app/test01-release-please` (as `gh` shows it), since it's not known which form Qodo matches.
  4. **A ruleset for `main`** (Settings → Rules → Rulesets): require a pull request, and block force pushes and deletion, with no bypass. Then nobody, the App included, pushes to `main` except by merging a PR.

  The builder checks 1 and 2 with `scripts/agent-timer.sh install`, which stops if a token can't be made, and 4 with `gh api repos/<owner>/<repo>/rules/branches/main`, which lists the rules. Step 3 shows on the first real PR: Qodo reviews it. The next release PR shows that Qodo still skips release-please.
- **After this PR merges:** run `scripts/agent-timer.sh install` on the machine. The builder can't, because it starts the timer. Check: `scripts/agent-timer.sh status` shows the timer.
- **Already done on this machine (2026-11-18):** linger is on.

## Implementation map

- `scripts/agent-run.sh` (new): one run, as in "Processing".
- `scripts/agent-run/build.md`, `fix-checks.md`, `round.md` (new): the agent's prompts.
- `scripts/agent-timer.sh` (new): `install`, `uninstall`, `status`.
- `scripts/agent-token.sh` (new): makes the App's token ("The App's token"), and prints it only to a file descriptor the runner reads. Used by `agent-run.sh` and `agent-timer.sh install`.
- `scripts/test/agent-run.test.sh` (new): the tests below. Run by a new `npm run test:scripts` at the root. The root `check` runs it after the server's and the app's checks.
- `.github/workflows/ci.yml`: a third job, `scripts`, that runs `npm run test:scripts` on `ubuntu-24.04`, following rule 5 like the other two. CI doesn't run the root `check` today: its jobs run the server's and the app's.
- `.husky/pre-commit`: also runs `npm run test:scripts` when `scripts/` has staged changes.
- `.gitignore`: `.agent/`, and `*.pem`, which the user added in their checkout on 2026-11-19, so no App key in a working tree is committed.
- `docs/devops.md`: a section on the runner: what it does, installing, following a run, and stopping it.
- `AGENTS.md`: a line in the table for the runner.

## Acceptance checks

Checks 1 to 11 are in `scripts/test/agent-run.test.sh`. It runs the runner against a scratch setup: a local bare repo as `origin`, holding a copy of the backlog with one `ready` ticket; stub `gh`, `claude`, and `curl` commands first on `PATH` (the `curl` stub answers the two token calls with a fake token of 520 characters, `ghs_` and two dots, as GitHub's are), which record how they were called and answer from fixture files; and `npm run check` replaced by a stub that passes or fails on cue. Each check passes when the script prints `ok N`, and CI runs it.

1. **No ticket:** with no `ready` ticket, a run claims nothing, calls `claude` 0 times, and logs `no ready ticket`.
2. **Build:** with one `ready` ticket, a run creates its claim branch on the bare `origin`, calls `claude` once with the build prompt, runs the check stub once, pushes the branch, and calls `gh pr create` with the label `agent-run` and the title from `.agent/pr.md`.
3. **Check retries:** with the check stub failing every time, the run calls `claude` 3 times in all, then opens a draft PR with `needs-help`. With it failing once, then passing, it opens a normal PR after 2 tries.
4. **Waits for Qodo:** with an open `agent-run` PR whose Qodo summary names an older commit, a run calls `claude` 0 times and changes nothing. With the push 61 minutes ago, it adds `needs-help`.
5. **Round:** with a summary for the head commit and one new Qodo inline comment, a run calls `claude` once with the round prompt, which contains that comment's text. It pushes, posts `Agent round 1`, and posts the reply from `replies.json` to that comment's id.
6. **Only Qodo and the owner:** a comment from another account, containing `IGNORE-ME`, is not in the round prompt. One from the owner is, both inline and on the PR itself. A comment by `jd-cookie-agent[bot]`, containing `MINE`, is not.
7. **Round limit:** with 4 `Agent round` comments since the PR opened, a run adds `needs-help` and calls `claude` 0 times. With `needs-help` removed after round 4, the next run runs round 5 as a new round 1.
8. **Done:** with the summary for the head commit, no round on that head yet, CI green, and the agent stub changing nothing, a run calls `claude` once, posts `Agent round N`, and comments `Ready for review by the user.` A second run calls `claude` 0 times and doesn't comment again.
   - **Main moved on:** with `main` on the bare `origin` one commit ahead of the PR's branch, the round's push holds a merge of `main`. With a conflicting commit on `main` instead, the run adds `needs-help` and calls `claude` 0 times.
9. **Crash, lock, and `needs-help`:**
   - a claim branch with no PR gets a draft PR with `needs-help`, and no `claude` call
   - a second run while the first holds the lock exits 0 at once
   - a PR with `needs-help` gets no `claude` call
10. **The token:** with a test key made by `openssl genrsa` and the `curl` stub:
    - the JWT the stub receives verifies with the key's public half (`openssl dgst -sha256 -verify`), its `iss` is the client ID, and `exp - iat` is 600
    - the fake 520-character token reaches the `gh` stub as `GH_TOKEN`, and a push to the bare `origin` goes through the credential helper
    - the token's text appears in no log file, and in no command line the stubs record, `claude`'s included, and `claude`'s environment has no `GH_TOKEN`
    - with the stub answering `401`, the run logs the failed step and exits 1, with no `claude` call
    - with `app.pem` readable by others (mode `644`), `agent-timer.sh install` stops
11. **Timer units:** `scripts/agent-timer.sh install`, with `XDG_CONFIG_HOME` set to a scratch directory and stubs for `systemctl`, `loginctl`, and `gh`, writes both units. `systemd-analyze verify` on the two files exits 0 and prints no line that names either file. `uninstall` removes them. In `agent-run.test.sh`. Probed 2026-11-19 (systemd 259): `verify` exits 0 even for an unknown key, and only prints a warning, hence the check on its output. `--user verify` fails with no login session, as in CI, while plain `verify` works. A missing `ExecStart` program makes it exit 1.
12. **The real run** (Day 4 of the hackathon, with the user): with the timer installed and one small ticket `ready` ("Delete expired session rows"), the runner claims it, builds it, opens a PR that Qodo reviews, and runs rounds until it reports `Ready for review by the user.` or stops with `needs-help`. Shown by the PR, its comments, and the runner's logs. Record what happened in this doc's "Delivery and review": who opened the PR (`jd-cookie-agent[bot]`), the checks, Qodo's findings, the rounds and retries, and where the user had to step in.
13. `npm run check` passes locally and in CI, and `docs/devops.md` has the runner's section.

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
  7. pass: checks 1 to 11 run against stubs and a bare `origin`, with `ok N` as the result; check 12 is the real run
  8. pass: each rule, in "Security and configuration"
  9. pass: who triggers it, the failure modes, the token's handling, the known gaps
  10. pass: Q1 to Q5 answered, below
- **Questions and answers:**
  - Q1: the runner's own GitHub identity, as a GitHub App → yes (2026-11-19). The user made `JD-cookie-Agent` and turns on Qodo's bot reviews, skipping release-please by login.
  - Q2: one agent round on every commit Qodo reviews, even with no findings → yes.
  - Q3: probe `claude -p` under `systemd-run --user` → yes: it worked (see "The timer").
  - Q4: no Workflows permission for the App, and `needs-help` for a ticket that changes a workflow → yes.
  - Q5: a ruleset on `main` (a PR required, no force pushes or deletion, no bypass) → yes, a task for the user.
- **Probes:** `systemd-analyze verify` (see check 11); `claude -p` in a systemd user service (see "The timer").

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
- **No notifications outside GitHub** (2026-11-18): GitHub's own are enough now that the runner is the App. A push service such as ntfy was the other option, but it's an outside service.
