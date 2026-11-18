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
- Notifying the user outside GitHub. The user checks the `agent-run` PRs (see "Decisions made for this ticket").
- Starting on a label or a push instead of a timer. A timer is enough for one ticket at a time.

## Concepts

- **Runner:** `scripts/agent-run.sh`. One run does one step and exits. It holds no state of its own between runs: the state is in GitHub, in the ticket's branch, its PR, the PR's labels and comments, and Qodo's review.
- **Timer:** a systemd **user** timer. systemd is Linux's service manager. A user timer runs under the user's own account, with no root. With "linger" on (`loginctl enable-linger`), it runs while the user is logged out too.
- **Agent:** Claude Code in headless mode (`claude -p`), run by the runner in the runner's own clone of the repo.
- **Round:** one pass of the agent over the review results of one push: Qodo's findings and failed CI jobs. It ends with a push, or with "nothing left to fix".
- **`needs-help`:** a PR label. The runner adds it when it stops for the user, and does nothing more on that PR while it's there.

## User-facing behavior

For the user:
1. Install and start the timer once per machine: `scripts/agent-timer.sh install`. `scripts/agent-timer.sh status` shows the timer and the last run's log. `scripts/agent-timer.sh uninstall` stops it and removes it.
2. Mark a ticket `ready` as usual. Within 15 minutes, the runner claims it.
3. Follow it on GitHub: its PR carries the label `agent-run`. Each round adds a comment from the runner that starts `Agent round N`. When it's done, it comments `Ready for review by the user.`
4. If it stops for help, the PR gets the label `needs-help` and a comment that says why. To let it go on, fix what's needed, then remove the label. Removing it resets the retry counts.
5. Merge, or close the PR, as for any PR.

The runner pushes and comments with the user's own GitHub login (the `gh` and `git` credentials on the machine). So the PRs are the user's, like every PR in this repo, and Qodo reviews them. Qodo didn't review release-please's PR #4, which came from a GitHub App.

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

1. In the clone: `git fetch`, then switch to a clean `main` at `origin/main`. Then `npm ci` at the root and in `server/` and `app/`, so the hooks and checks run as in CI.
2. `scripts/ticket.sh claim next "runner-$(hostname -s)"`. On exit 3 (no free ticket), exit 0. On any other code but 0, log it and exit 1: the next run tries again.
3. **Build**, try 1 of 3: run the agent with the build prompt (see "The agent"). It follows the `next-ticket` skill's step 2, and commits, but doesn't push.
4. **Checks:** the runner itself runs `npm run check` in the clone. It doesn't take the agent's word for it.
   - **Pass:** go to 5.
   - **Fail:** run the agent again with the fix prompt and the check's output (the last 200 lines), then check again. That's try 2, then try 3.
   - **Still failing after 3 tries:** push the branch, open a draft PR with the labels `agent-run` and `needs-help`, and comment "The checks still fail after 3 tries." with the last 200 lines of output. Exit.
5. **Push and open the PR:** push the branch, then `gh pr create` with the title and body the agent wrote to `.agent/pr.md` in the clone: the first line is the title, the rest is the body, as `next-ticket` step 3 describes. Add the label `agent-run`. `.agent/` is git-ignored.

### Review step

For the open PR without `needs-help`:

1. **Wait for the review.** Qodo is done with the head commit when its summary comment, the issue comment by `qodo-code-review[bot]` that starts "Code Review by Qodo", contains `<!-- https://github.com/<owner>/<repo>/commit/<head sha> -->`. CI is done when `gh pr checks` has no pending check.
   - **Either isn't done:** exit, and check again next run.
   - **Still not done 60 minutes after the push:** add `needs-help`, with the comment "Qodo or CI hasn't finished reviewing <sha> after 60 minutes." Exit.
2. **Collect what's new since the last round,** for the round prompt:
   - Qodo's whole summary comment: some findings are only there.
   - Inline review comments by `qodo-code-review[bot]`, and by the repo owner (`gh api repos/<owner>/<repo> --jq .owner.login`), posted after the last `Agent round` comment.
   - For each failed CI job, its failed log lines (`gh run view <id> --log-failed`, the last 200 lines).

   Comments from anyone else are left out: the repo is public, so anyone can comment, and the agent would read their text as instructions.
3. **Nothing new, and CI green:** if the runner hasn't commented `Ready for review by the user.` on this head commit yet, it comments that now. Exit. If the summary has no open finding, there's nothing new.
4. **Count rounds.** A round is an `Agent round N` comment from the runner, counted since the last time `needs-help` was removed from the PR (the PR's timeline, event `unlabeled`), or since the PR opened. If 4 rounds are done, add `needs-help`, with the comment "Qodo still has findings after 4 rounds." Exit.
5. **Run a round:** switch the clone to the PR's branch at `origin`. Run the agent with the round prompt and the collected text. It writes `.agent/round.md`, with each finding, whether it's confirmed, and what it did: fixed (with the commit) or answered (with the reason). It also writes `.agent/replies.json`, with one reply per inline comment: `[{"comment_id": 123, "body": "…"}]`.
6. **Checks** as in the build step, 3 tries. If they still fail: push, add `needs-help`, and comment with the output. Exit.
7. **Push, then report:** comment `Agent round N` with the contents of `round.md`, and post each reply in `replies.json` as a reply to its comment (`gh api …/pulls/<n>/comments/<id>/replies`). Exit. The next run waits for Qodo's review of the new head.

A round that confirms nothing and changes nothing has nothing to push. The runner then posts `Agent round N` with the answers, and `Ready for review by the user.`

### The agent

Each run of the agent is a fresh `claude -p` process in the clone, with no MCP servers (`--strict-mcp-config`), a time limit of 45 minutes (`timeout 45m`), and its output saved to the run's log. Its permissions:
- **Allowed:** reading files, editing files in the clone, and these shell commands: `npm`, `node`, `npx`, `git status`, `git diff`, `git log`, `git show`, `git add`, `git mv`, `git rm`, `git commit`, `ls`, `cat`, `grep`, `find`, `head`, `tail`, `wc`, `mkdir`.
- **Denied:** `git push`, `gh`, `curl`, `wget`, and web tools. The runner script does every push and every GitHub call itself, so the agent can't change GitHub, and can't read PR comments the runner left out.

The three prompts live in `scripts/agent-run/` as Markdown files (`build.md`, `fix-checks.md`, `round.md`), with placeholders the runner fills in. Each one says:
- follow `AGENTS.md` and the `next-ticket` skill
- don't push, and don't touch `server/.env` or `server/data/`
- if the design doc is wrong or something needs the user's decision, write that to `.agent/stop.md` and stop. The runner then adds `needs-help`, with `stop.md` as the comment.

### The timer

`scripts/agent-timer.sh install` writes two units to `${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/`, runs `systemctl --user daemon-reload`, and `systemctl --user enable --now test01-agent.timer`:
- `test01-agent.service`: `Type=oneshot`, `ExecStart=<repo>/scripts/agent-run.sh`, where `<repo>` is the checkout `install` runs from. It sets the `PATH` from the user's shell at install time, so `node`, `npm`, `claude`, and `gh` are found.
- `test01-agent.timer`: `OnBootSec=5min`, `OnUnitInactiveSec=15min`, so a run starts 15 minutes after the last one ended.

It checks that linger is on (`loginctl show-user "$USER" -p Linger`). If it isn't, it says to run `sudo loginctl enable-linger "$USER"`, and installs anyway. It also checks that `claude`, `gh`, `node`, `npm`, and `flock` are on `PATH`, and that `gh auth status` passes, and stops if not. Running `install` again updates the units.

`uninstall` disables and stops the timer, and removes both units. It leaves the clone and the logs. `status` prints `systemctl --user list-timers test01-agent.timer` and the last run's log.

### Logs

Each run writes a log to `${XDG_STATE_HOME:-$HOME/.local/state}/test01-agent/logs/<UTC time>.log`: each step it took, the commands it ran with their exit codes, and the agent's output. It keeps the last 200 logs. The journal also has each run's output: `journalctl --user -u test01-agent`.

## Security and configuration

- **Who can trigger it:** only the timer, or the user running the script. Its input is `main` (only the user merges), the runner's own branches and PRs, and comments from Qodo and the repo owner.
- **Credentials:** the machine's `gh` and `git` logins, which the user's token limits to this repo. The agent itself can't push or call GitHub. Its Claude login is the user's.
- **Untrusted text:** comments by other accounts are never passed to the agent. Qodo's text is passed, but the agent can only change files in its clone, and the checks and Qodo's next review see everything it changes.
- **Failure modes:**
  - GitHub can't be reached: the run logs the failed command and exits 1. The next run tries again.
  - The agent fails or times out: that counts as a failed try.
  - Two runs at once: the lock.
  - A crash mid-build: the next run finds a claim with no PR and stops for help.
- **No new settings.** The interval, the limits, and the labels are constants at the top of `agent-run.sh`.
- **Known gaps:**
  - The runner comments as the user, so GitHub doesn't notify the user of its comments. The user checks the `agent-run` PRs instead.
  - The agent can run `npm` scripts, which can run any code in the repo, like the hooks and tests already do.
  - The time limit doesn't cap cost. `--max-budget-usd` only applies to API keys, and this uses the user's login.

## Tasks for the user

- **Before the first real run, after this PR merges:** run `scripts/agent-timer.sh install` on the machine. The builder can't, because it starts the timer. Check: `scripts/agent-timer.sh status` shows the timer.
- **Already done on this machine (2026-11-18):** linger is on, and `gh` is logged in with access to the repo.

## Implementation map

- `scripts/agent-run.sh` (new): one run, as in "Processing".
- `scripts/agent-run/build.md`, `fix-checks.md`, `round.md` (new): the agent's prompts.
- `scripts/agent-timer.sh` (new): `install`, `uninstall`, `status`.
- `scripts/test/agent-run.test.sh` (new): the tests below. Run by a new `npm run test:scripts` at the root, which `npm run check` also runs.
- `.gitignore`: `.agent/`.
- `docs/devops.md`: a section on the runner: what it does, installing, following a run, and stopping it.
- `AGENTS.md`: a line in the table for the runner.

## Acceptance checks

Checks 1 to 9 are in `scripts/test/agent-run.test.sh`. It runs the runner against a scratch setup: a local bare repo as `origin`, holding a copy of the backlog with one `ready` ticket; stub `gh` and `claude` commands first on `PATH`, which record how they were called and answer from fixture files; and `npm run check` replaced by a stub that passes or fails on cue. Each check passes when the script prints `ok N`, and CI runs it.

1. **No ticket:** with no `ready` ticket, a run claims nothing, calls `claude` 0 times, and logs `no ready ticket`.
2. **Build:** with one `ready` ticket, a run creates its claim branch on the bare `origin`, calls `claude` once with the build prompt, runs the check stub once, pushes the branch, and calls `gh pr create` with the label `agent-run` and the title from `.agent/pr.md`.
3. **Check retries:** with the check stub failing every time, the run calls `claude` 3 times in all, then opens a draft PR with `needs-help`. With it failing once, then passing, it opens a normal PR after 2 tries.
4. **Waits for Qodo:** with an open `agent-run` PR whose Qodo summary names an older commit, a run calls `claude` 0 times and changes nothing. With the push 61 minutes ago, it adds `needs-help`.
5. **Round:** with a summary for the head commit and one new Qodo inline comment, a run calls `claude` once with the round prompt, which contains that comment's text. It pushes, posts `Agent round 1`, and posts the reply from `replies.json` to that comment's id.
6. **Only Qodo and the owner:** a comment from another account, containing `IGNORE-ME`, is not in the round prompt. One from the owner is.
7. **Round limit:** with 4 `Agent round` comments since the PR opened, a run adds `needs-help` and calls `claude` 0 times. With `needs-help` removed after round 4, the next run runs round 5 as a new round 1.
8. **Done:** with the summary for the head commit, nothing new, and CI green, a run comments `Ready for review by the user.` once. A second run doesn't comment again.
9. **Crash, lock, and `needs-help`:**
   - a claim branch with no PR gets a draft PR with `needs-help`, and no `claude` call
   - a second run while the first holds the lock exits 0 at once
   - a PR with `needs-help` gets no `claude` call
10. **Timer units:** `scripts/agent-timer.sh install`, with `XDG_CONFIG_HOME` set to a scratch directory and a stub `systemctl`, writes both units, and `systemd-analyze --user verify` accepts them. `uninstall` removes them. In `agent-run.test.sh`.
11. **The real run** (Day 4 of the hackathon, with the user): with the timer installed and one small ticket `ready` ("Delete expired session rows"), the runner claims it, builds it, opens a PR that Qodo reviews, and runs rounds until it reports `Ready for review by the user.` or stops with `needs-help`. Shown by the PR, its comments, and the runner's logs. Record what happened in this doc's "Delivery and review": the checks, Qodo's findings, the rounds and retries, and where the user had to step in.
12. `npm run check` passes locally and in CI, and `docs/devops.md` has the runner's section.

## Decisions made for this ticket

Decided by the user on 2026-11-18:
- **A systemd user timer on the user's machine, installed by a script,** so a new machine is set up with one command. Not GitHub Actions: its PRs would come from a bot, which Qodo may not review, and it would need an API key secret in a public repo. Not T3 Code's scheduled tasks: nothing would be in the repo to review or reuse.
- **One step per run, with the state in GitHub.** A reboot or a crash loses nothing, and every run leaves a log.
- **Retry limits:** 3 tries to get the checks green, 4 Qodo rounds. Then `needs-help`, and the runner waits for the user.
- **Only Qodo's and the repo owner's comments reach the agent,** because anyone can comment on a public repo.
- **Claude Code (`claude -p`) in its own clone.** It never merges, never pushes (the runner does), and never touches `server/.env` or the development database.
- **One ticket at a time, and the user starts the timer.**
- **No notifications outside GitHub for now:** the user checks the PRs labeled `agent-run`. The runner comments as the user, so GitHub sends no notification, and this machine has no desktop. A push service such as ntfy was the other option, but it's an outside service.
