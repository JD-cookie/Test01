# A runner that builds a ready ticket into a PR

Status: **designed**. When the user marks it `ready`, it gets a number and this doc is renamed `NNN-agent-build.md`. It moves to `docs/features/` in the PR that builds it.

This is part 1 of 3, split on 2026-11-19 from "An agent that builds ready tickets on a timer", which was too big for one PR (Definition of Ready, item 4):
1. **This one:** the runner, run by hand, claims a `ready` ticket, builds it, gets the checks green, and opens the PR as the App.
2. [The runner fixes Qodo's findings on its PRs](agent-review-rounds.md): the review step. Blocked by this one.
3. [Start the runner on a timer](agent-timer.md): the systemd timer. Blocked by both.

## Summary

Today an agent builds a ticket only when the user opens a session and asks. This part adds the **runner**, `scripts/agent-run.sh`. The user runs it by hand, and one run does the next step for the runner's own ticket:
- claim the next free `ready` ticket and build it, with Claude Code in headless mode
- get the checks green, up to 3 tries, with the checks in a sandbox
- open a PR for Qodo to review, as the App `jd-cookie-agent[bot]`, not as the user

It stops and asks for help, with a draft PR labeled `needs-help`, when it can't get there. The user then takes the PR through review, as for any PR, until part 2 adds the fix rounds. The user still decides what's `ready` and still merges every PR.

It's for the user, who wants tickets built without starting each one by hand. It's the first of the three parts because the other two build on it: the review rounds reuse its agent, sandbox, token, and "Stopping for help", and the timer only starts it.

What doesn't change:
- how tickets are made `ready`
- the claim rules in `scripts/ticket.sh`
- the `next-ticket` skill, which the runner's agent follows
- the review rules: Qodo reviews every PR, and every finding is fixed or answered
- the user merges

### Out of scope

- The review step: rounds on Qodo's findings and CI failures. That's part 2. Until it's built, a run that finds its PR open does nothing.
- The timer, and the trusted copy of the runner in `bin/` that the timer runs. That's part 3.
- Marking tickets `ready`, refining them, or merging PRs.
- More than one ticket at a time, or more than one runner per machine. Runners on two machines don't collide, since each works only on its own claims (`runner-<machine id>`), but only one machine is meant to run it.
- Running in GitHub Actions or the cloud (see "Decisions made for this ticket").
- Reviews by our own agents. That's its own backlog item: "Code reviews by our own agents".
- Notifying the user outside GitHub. The runner is its own GitHub identity, so GitHub notifies the user of its PRs and comments as for anyone's.

## Concepts

- **Runner:** `scripts/agent-run.sh`. One run does one step and exits. It holds no state of its own between runs: the state is in GitHub, in the ticket's branch, its PR, and the PR's labels.
- **Agent:** Claude Code in headless mode (`claude -p`), run by the runner in the runner's own clone of the repo.
- **`needs-help`:** a PR label. The runner adds it when it stops for the user, and does nothing more on that PR while it's there.
- **The App:** `JD-cookie-Agent`, a GitHub App installed only on this repo, made by the user on 2026-11-19. GitHub derives its bot user from the name, in lower case: `jd-cookie-agent[bot]`, user id 358547770 (`gh api 'users/jd-cookie-agent[bot]'`). On this machine, the runner's folders, lock file, and (in parts 2 and 3) comment marker and systemd units use the same name, `jd-cookie-agent` (renamed from `test01-agent` on 2026-11-19, at the user's request, so there's one name for one thing). It's the runner's identity on GitHub: its PRs, comments, labels, and pushes come from `jd-cookie-agent[bot]`, not from the user.

## User-facing behavior

For the user:
1. Once per machine: `scripts/agent-run.sh check` checks the tools, the sandbox, and the App's key, and makes a token, without changing anything.
2. Mark a ticket `ready` as usual, then run `scripts/agent-run.sh` in the user's checkout. It claims the ticket and builds it in its own clone. A build can take a few hours at most: three agent tries of up to 45 minutes, and their checks.
3. Follow it on GitHub: its PR carries the label `agent-run`, and comes from `jd-cookie-agent[bot]`. Take it through Qodo's review as for any PR.
4. If it stops for help, its PR is a draft with the label `needs-help`, and its description says why. Fix what's needed by hand, then mark it ready for review.
5. Merge, or close the PR, as for any PR. A later run, by hand, then builds the next `ready` ticket.

The runner pushes, opens PRs, and comments as the App `jd-cookie-agent[bot]` (see "The App's token"). So the user gets GitHub's notifications for them, and can review its PRs like anyone else's. Qodo reviews them once the user has turned on bot reviews in Qodo, with release-please's App on Qodo's skip list (see "Tasks for the user"): Qodo didn't review release-please's PR #4, because bot reviews were off.

## Processing

### One run

`scripts/agent-run.sh` with no arguments does one run. `scripts/agent-run.sh check` does only the checks in "Checking the setup". It works in its own clone, `${XDG_DATA_HOME:-$HOME/.local/share}/jd-cookie-agent/repo`, and never in the user's checkout. It clones `origin` there if that clone doesn't exist. Its agent name for claims is `runner-<id>`, where `<id>` is the first 12 characters of `/etc/machine-id`, which is unique to each installed system, unlike a short host name.

The agent can edit everything in the clone, so nothing the runner trusts is read from it: the runner's prompts and Claude settings come from the folder the running script is in (`scripts/agent-run/` beside it), and the commitlint config from `main` (see the title check). Run by hand, that's the user's checkout, which the agent never touches. Part 3 makes the timer run a copy instead.

1. **Lock.** It takes `flock -n` on `${XDG_RUNTIME_DIR}/jd-cookie-agent.lock`. If another run holds it, it exits 0. If `XDG_RUNTIME_DIR` isn't set, or the lock file can't be opened, it exits 1 with a message to run it from a login session: a login session and a systemd user service both have it (probed for the service, see part 3). The lock is per machine. A runner on a second machine has another agent name, so it only works on its own claims (step 2), and the two never touch the same PR.
2. **Find its work.** It looks only at its own tickets: branches on `origin` whose claim commit, the first commit after `main` on the branch, has the trailer `Claimed-By: runner-<id>` with its own agent name. For each one, it looks up the branch's PRs in every state (`gh pr list --head <branch> --state all`):
   - **A merged or closed PR:** that ticket is over. Skip it. The user deletes its branch when they like; until then, the claim keeps other agents off it.
   - **An open PR:** it's in review, with the user (and, once part 2 is built, with the review step). Log `PR #<n> is open` and exit.
   - **No PR:** an earlier run died while building, for example in a reboot, or `gh pr create` failed after the push. Stop for help, as in "Stopping for help": if the clone still has the branch with commits that `origin` doesn't, they're saved and pushed; then the draft PR opens, with the reason "A run stopped while building this ticket. Its work so far is on this branch." It's the same every time it runs, so a run that dies partway through it is finished by the next.
   - **None of its tickets has an open PR:** if `scripts/ticket.sh list` shows a free `ready` ticket, build step (below). If not, log `no ready ticket` and exit.

   Only one ticket is in progress at a time: the runner doesn't start a new one while any of its PRs is open, `needs-help` or not.
3. **A token for each phase.** It makes a new App token (see "The App's token") right before each group of GitHub calls and pushes: when it finds its work, after each agent run, and before each push. Each token lasts an hour, and a run can last longer: three agent tries of up to 45 minutes each.

### Build step

1. In the clone: `git fetch`, then switch to a clean `main` at `origin/main`, and delete every other local branch: the clone is the runner's own, and what matters is on `origin`. A local branch left by a run that failed would make the next claim fail. Then `npm ci` at the root and in `server/` and `app/`, so the hooks and checks run as in CI.
2. `scripts/ticket.sh claim next "runner-<id>"`. Its exit codes (see `scripts/ticket.sh`):
   - **0:** claimed. The script has already pushed the claim branch, `NNN-slug`, whose commit has the trailer `Claimed-By: runner-<id>`.
   - **3:** no free ticket. Exit 0.
   - **5:** claimed, but the ticket was withdrawn or changed on `main` meanwhile. Stop, as in "Stopping for help", with the script's message.
   - **anything else (2, 4):** log the message and exit 1. If the claim reached `origin` after all, the next run finds the branch with no PR, and stops for help.
3. **Build**, try 1 of 3: run the agent with the build prompt (see "The agent"). It follows the `next-ticket` skill's step 2, and commits, but doesn't push. If it wrote `.agent/stop.md`, stop, as in "Stopping for help", with `stop.md` as the comment.
4. **Checks:** first, the clone must have no changes the agent didn't commit: `git status --porcelain` lists nothing (`.agent/` is ignored). If it lists something, that's a failed try, with the list as its output, so the checks always test what gets pushed. Then the runner itself runs `npm run check` in the clone, in the sandbox (see "The agent"), with a time limit of 20 minutes (`timeout --kill-after=1m 20m`). A check that runs out of time is a failed try. The runner doesn't take the agent's word for it. After the checks and the title check, the clone must still be clean and at the same `HEAD`: the checks run code the agent wrote, which could change a tracked file and test that instead. If not, that's a failed try too.
   - **Pass:** go to 5.
   - **Fail:** run the agent again with the fix prompt and the check's output (the last 200 lines), then check again. That's try 2, then try 3.
   - **Still failing after 3 tries:** stop, as in "Stopping for help", with "The checks still fail after 3 tries." and the last 200 lines of output.

   The tries are counted in the run itself. They can't repeat across runs: a run that dies mid-build leaves a branch with no PR, and the next run stops for help.
5. **The title:** the agent writes `.agent/pr.md`: the first line is the PR's title, the rest is its body, as `next-ticket` step 3 describes. The runner checks the title with commitlint and `main`'s config, as `pr-title.yml` does with the base branch's: after the agent's run, `git show origin/main:commitlint.config.mjs > .agent/commitlint.config.mjs` in the clone, then `printf '%s\n' "$title" | ./node_modules/.bin/commitlint --config .agent/commitlint.config.mjs`, in the sandbox, with a time limit of 2 minutes (`timeout --kill-after=10s 2m`). The copy goes in the clone, not the run's folder, because commitlint resolves the config's `extends` (`@commitlint/config-conventional`) from the config's own folder: probed 2026-11-19, a copy in a folder outside the repo fails every title with `Cannot find module "@commitlint/config-conventional"`, while a copy in `.agent/` of a checkout passes a good title (exit 0) and fails a bad one (exit 1), in `bwrap`. commitlint itself, in the clone's `node_modules`, is JavaScript the agent could have changed, so the check gets no token and no network. At worst it passes a bad title, and `pr-title.yml` fails it in CI. If it fails, that's a failed check, with commitlint's output, and goes to the fix prompt like the others.
6. **Push and open the PR:** push the branch, then `gh pr create --label agent-run` with that title and body. Labels are added and removed later with `gh api` (`repos/<owner>/<repo>/issues/<n>/labels`), because `gh pr edit` fails in the installed `gh` 2.46. The runner creates the labels `agent-run` and `needs-help` when it first needs them and they don't exist (`gh label create`, with the App's token). Neither exists in the repo today. A push that GitHub refuses because the branch changes `.github/workflows/` stops the build, as in "Stopping for help". If `gh pr create` fails after the push, the run exits 1, and the next run finds the branch with no PR.

### Stopping for help

Whenever the runner stops for the user, it does the same. In this part, that's always before a PR exists. Part 2 adds the same stop for an open PR.
1. **Save the work.** In the run's folder, `${XDG_STATE_HOME:-$HOME/.local/state}/jd-cookie-agent/runs/<UTC time>/`, it writes:
   - `base.txt`: the commit the saved work starts from: `origin/<branch>` if the branch is on `origin`, or else the `main` commit the claim started from.
   - `commits.bundle`: `git bundle create commits.bundle <base>..HEAD`, only if `HEAD` has commits after the base (git refuses an empty bundle). A bundle, not `format-patch`, because `format-patch` leaves out merge commits, and part 2's rounds merge `main` (probed 2026-11-19: a range with a merge gave 2 patches and no merge; the bundle kept the merge).
   - `uncommitted.patch`: from `git add -A` and `git diff --cached --binary HEAD`, then `git reset -q`, only if there's a change. `git add -A` takes untracked files too, except ignored ones, and `--binary` keeps binary files.

   To restore in a fresh clone: check out `base.txt`'s commit; if `commits.bundle` exists, `git fetch <run folder>/commits.bundle HEAD` and `git checkout FETCH_HEAD`; if `uncommitted.patch` exists, `git apply` it. Files that weren't needed aren't written, since `git am` fails on an empty patch (probed: "Patch format detection failed", exit 128). That works whether or not step 2 pushes the commits afterwards.
2. **Push** the branch if it has commits that `origin` doesn't, unless the reason for stopping is that GitHub refused the push (a workflow change). Then `origin` keeps only what's there, and the PR's description names the saved files.
3. **Open a draft PR** from the branch with the labels `agent-run` and `needs-help`, with the title from `.agent/pr.md` if it passes the title check, or else `chore(repo): build ticket NNN-slug`. Its description holds everything the user needs: the reason, the run folder's path, and the names of the saved files first, then the last 200 lines of output if there are any, then the body from `pr.md` if there is one. The whole description is kept under 60,000 characters, below GitHub's limit of 65,536: the reason is cut to 5,000 if it's longer, and the output and the body are cut, from their start, to fit what's left, with a line that says so. The run's folder keeps them whole. It's one call, so a crash leaves either no PR, which the next run handles as above, or a complete one: never a draft that doesn't say why.

### The agent's files

`.agent/` in the clone is git-ignored. The runner empties it before each agent run, so an old file can't pass for a new one. After the run, it checks what the step needs. A missing or invalid file counts as a failed try:
- `pr.md`: a non-empty first line. Every agent run writes it, the fix tries included: the fix prompt gives the last `pr.md`, to keep or change.

### The agent

Each run of the agent is a fresh `claude -p` process in the clone, with no MCP servers (`--strict-mcp-config`), a time limit of 45 minutes (`timeout --kill-after=1m 45m`: without `--kill-after`, a process that ignores SIGTERM keeps running, probed 2026-11-19), and its output saved to the run's log. Its permissions:
- **Allowed:** reading files, editing files in the clone, and these shell commands: `npm`, `node`, `npx`, `git status`, `git diff`, `git log`, `git show`, `git add`, `git mv`, `git rm`, `git commit`, `ls`, `cat`, `grep`, `find`, `head`, `tail`, `wc`, `mkdir`.
- **Denied:** `git push`, `gh`, `curl`, `wget`, and Claude's web tools beyond those below. The runner script does every push and every GitHub call itself, so the agent can't change GitHub with a token. These are Claude's tool rules, not a network limit: an allowed `node` or `npm` command can still reach any host (see "Known gaps").
- **Docs on the web** (the user's decision, 2026-11-19): `WebSearch`, and `WebFetch` only for these documentation sites: `docs.expo.dev`, `reactnative.dev`, `nodejs.org`, `developer.mozilla.org`, `fastify.dev`, `www.typescriptlang.org`, `docs.github.com`, `docs.npmjs.com`, `www.npmjs.com`, `sqlite.org`, `valkey.io` (as `WebFetch(domain:<site>)` rules). `app/AGENTS.md` requires the versioned Expo docs before code that touches Expo's APIs. The prompts say to look in `node_modules` first: the docs, type definitions, and READMEs of the exact installed versions. A fetch outside the list is refused, and the run log shows it, so the list can grow from what's missing.
- **Secret folders:** Claude's permission rules deny `Read` and `Edit` of the three secret folders (see the sandbox below). `settings.json` names them as placeholders, `{{APP_CONFIG}}`, `{{GH_CONFIG}}`, and `{{SSH}}`; the runner fills in the resolved paths in a copy in the run's folder, and passes that copy. These rules are enforced by Claude Code, not by the OS: an allowed `node -e` can still read the files (see "Known gaps").

The permissions are in `scripts/agent-run/settings.json`, read from the runner's own folder, never from the clone, filled in, and passed with `--settings`, so the agent can't change them for its next try. They're reviewed like code. Tools not allowed there are refused, since `claude -p` has nobody to ask.
- **No token:** the runner starts `claude`, `npm run check`, and the title check with `GH_TOKEN` and the credential helper's variables removed from their environment (`env -u GH_TOKEN -u GIT_CONFIG_COUNT …`; see "The App's token"), and also without `VALKEY_URL` (below). Inside the sandbox it sets `AGENT_RUN_IN_SANDBOX=1`, so the runner's own tests know where they are (see "Acceptance checks").
- **The checks in a sandbox:** `npm run check` runs code the agent wrote, so the runner runs it in `bwrap` (bubblewrap): the whole file system read-only except the clone, `/tmp` (a private `tmpfs`), and the npm cache; empty folders over the secret folders; its own process list (`--unshare-pid --proc /proc`); and its own empty network namespace (`--unshare-net`). The secret folders are resolved when the runner starts: `${XDG_CONFIG_HOME:-$HOME/.config}/jd-cookie-agent`, `${GH_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/gh}`, and `~/.ssh`, so a different `XDG_CONFIG_HOME` moves the masks with the key. Probed 2026-11-19: reading a hidden file through another process, `/proc/<pid>/root/…`, was refused even without `--unshare-pid` ("Permission denied"), but the machine's processes were visible, which `--unshare-pid` hides. Probed 2026-11-19: inside such a sandbox, `app.pem`, `~/.config/gh/hosts.yml`, and `~/.ssh/github_test01` couldn't be read, the home folder couldn't be written, and the server's tests passed (23 of 23, Valkey's skipped). Ubuntu's AppArmor profile for `bwrap` also refuses every network socket inside it ("failed to open socket: Permission denied"), but `--unshare-net` doesn't depend on that profile. Probed 2026-11-19: with `--unshare-net`, the sandbox has only its own `lo`, and a listener on the host's `127.0.0.1`, which answered from outside, couldn't be reached from inside. The AppArmor profile is also why the agent itself can't run in `bwrap`: `claude` couldn't reach its API there (`EAI_AGAIN`).
- **No hooks on push:** every push the runner makes after the first agent run is `git -c core.hooksPath=/dev/null push`. The agent can edit `.husky/`, and a `pre-push` hook it added would otherwise run while the token is in the environment. Commit hooks still run, for the agent's commits. The claim's push, inside `scripts/ticket.sh`, comes before any agent run, on a clean `main`, so its hooks are `main`'s, which the user merged.
- **Valkey:** the agent's checks run without `VALKEY_URL`, removed from their environment even if the user's shell sets it (the server's Valkey tests run only when it's set, and the sandbox has no network to reach Valkey), so the Valkey tests are skipped there, as `AGENTS.md` describes. CI runs them with a Valkey service on every push.

The prompts live in `scripts/agent-run/` as Markdown files (`build.md`, `fix-checks.md`), with placeholders the runner fills in. Each one says:
- follow `AGENTS.md` and the `next-ticket` skill
- don't push, and don't touch `server/.env` or `server/data/`
- if the design doc is wrong or something needs the user's decision, write that to `.agent/stop.md` and stop. The runner then stops for help, with `stop.md` as the reason.

### The App's token

The runner needs a token for every GitHub call and push. It makes a new one before each phase of a run ("One run", step 3). Each lasts an hour. `scripts/agent-token.sh` makes one:
1. **A JWT,** made with `openssl` from the App's private key, `${XDG_CONFIG_HOME:-$HOME/.config}/jd-cookie-agent/app.pem`: header `{"alg":"RS256","typ":"JWT"}`, payload `{"iat": <now - 60>, "exp": <now + 540>, "iss": "<client id>"}`, each part base64url-encoded, signed with `openssl dgst -sha256 -sign`. The client ID is in `${XDG_CONFIG_HOME:-$HOME/.config}/jd-cookie-agent/app.env`, as `APP_CLIENT_ID=…`. It isn't secret.
2. **The installation:** `GET /repos/<owner>/<repo>/installation`, with the JWT, gives the installation's `id`.
3. **The token:** `POST /app/installations/<id>/access_tokens` with the JWT, and the body `{"repositories": ["<repo>"]}`, so the token reaches only this repo, even if the App is ever installed on more. Both calls use `curl`, with the `Authorization` header read from a file (`-H @<file>` in a private temporary directory), so the JWT and the token never appear on a command line, where `ps` shows them.

The token is handled as an opaque string: GitHub's installation tokens start `ghs_`, are about 520 characters, and contain dots (since GitHub's stateless tokens rolled out, 2026-10-02). Nothing checks its length or shape. It reaches `gh` as `GH_TOKEN`, and `git` through a credential helper that reads it from the environment, with `origin` set to `https://github.com/<owner>/<repo>.git`. The helper is set only in the runner's own environment, with git's configuration variables, so every `git` command the runner runs has it, `scripts/ticket.sh`'s claim push included, and the clone's `.git/config` never does: `GIT_CONFIG_COUNT=2`, `GIT_CONFIG_KEY_0=credential.helper` with an empty value (which drops any helper from the user's config), and `GIT_CONFIG_KEY_1=credential.helper` with `!f() { echo username=x-access-token; echo "password=$GH_TOKEN"; }; f`. It's never written to a file, a log, or a URL. If any step fails, the run logs which one, with the HTTP status, and exits 1.

Commits in the clone, the claim commit included, have the App's bot as author and committer: `jd-cookie-agent[bot]` and `358547770+jd-cookie-agent[bot]@users.noreply.github.com`, with the id read from `GET /users/jd-cookie-agent[bot]` at run time, not hard-coded. GitHub then shows the commits as the App's.

The App's permissions, on this repository only, as the user set them up for all three parts:
- **Contents:** read and write, to push branches.
- **Pull requests:** read and write, to open PRs (and, in part 2, reply to review comments).
- **Issues:** read and write, for labels and PR comments.
- **Actions:** read, for the failed jobs' logs (part 2).
- **Checks** and **Commit statuses:** read, for `gh pr checks` (part 2).
- **Metadata:** read (always on).
- Not **Workflows**: a push that changes `.github/workflows/` is refused by GitHub. The runner then stops for help with the reason "This ticket changes a workflow, which the runner's App can't push." See "Decisions made for this ticket".

### Checking the setup

`scripts/agent-run.sh check` checks that `claude`, `gh`, `node`, `npm`, `curl`, `openssl`, `flock`, and `bwrap` are on `PATH`, that `bwrap` can hide a file (it makes a file in a temporary folder and checks it can't be read inside), that `bwrap` has no network (`/proc/net/dev` inside lists only `lo`; not `/sys/class/net`, which still shows the host's interfaces inside, and not a TCP listener, which can't be opened when the runner's own tests run inside the sandbox; probed 2026-11-19, also in a nested `bwrap`), that `app.pem` exists and only the user can read it (mode `600`), that `app.env` sets `APP_CLIENT_ID`, and that a token can be made (the steps of "The App's token"). It prints each result, and exits 1 if any fails. It writes nothing outside a temporary folder, and changes nothing on GitHub. A run does the same checks first, and stops if one fails. Part 3's `agent-timer.sh check` runs it too.

### Logs

Each run writes a log to `${XDG_STATE_HOME:-$HOME/.local/state}/jd-cookie-agent/logs/<UTC time>.log`: each step it took, the commands it ran with their exit codes, and the agent's output. It keeps the last 200 logs. The script also prints the log as it goes.

## Security and configuration

- **Who can trigger it:** only the user running the script (and, in part 3, the user's timer). Its input is `main` (only the user merges) and the runner's own branches and PRs.
- **Credentials:** the App's private key, on the user's machine only, readable only by the user, never in the repo. Each run's token lasts an hour and reaches only this repo, with the permissions above. The agent never has it. The user's own `gh` login and deploy key aren't used. The agent's Claude login is the user's.
- **Pushing to `main`:** the App's contents permission would let it push to `main`, and `main` has no ruleset today (`gh api repos/<owner>/<repo>/rules/branches/main` returns `[]`). The runner never pushes to `main`: it pushes only branches it claimed. See "Tasks for the user" for the ruleset.
- **Untrusted text:** this part passes no PR comments to the agent. Its input is the ticket's design doc on `main`.
- **Failure modes:**
  - GitHub can't be reached: the run logs the failed command and exits 1. The next run tries again.
  - The agent fails or times out: that counts as a failed try.
  - Two runs at once: the lock.
  - A crash mid-build: the next run finds a claim with no PR and stops for help.
- **The project's rules:**
  - Rule 1 (count before you check): the 3 tries are counted in the run before each try, and only one run works at a time (the lock), so no two runs count at once.
  - Rule 2 (no shared state in process memory): the runner keeps no state between runs. One runner per machine, and one ticket at a time, are out of scope for more.
  - Rule 3: `docs/devops.md` gets the runner's section in the same PR.
  - Rule 4: the runner's agent follows `next-ticket`, which leaves versions to release-please.
  - Rule 5: the new `scripts` CI job follows it. The runner itself runs outside GitHub Actions.
- **No new settings.** The limits and the labels are constants at the top of `agent-run.sh`. For the tests only, `AGENT_RUN_ORIGIN` replaces the clone's `origin` URL (by default `https://github.com/<owner>/<repo>.git`), and `AGENT_RUN_GITHUB_API` the API's base URL. The tests set `GIT_ALLOW_PROTOCOL=file`, so no git command in them can reach GitHub.
- **Known gaps:**
  - The agent can run `npm` scripts, which can run any code in the repo, like the hooks and tests already do.
  - The time limit doesn't cap cost. `--max-budget-usd` only applies to API keys, and this uses the user's login.
  - **The agent can read the machine's credentials:** it runs as the user, so an allowed command such as `node -e` can read `app.pem`, the user's `gh` token (`~/.config/gh/hosts.yml`), and the deploy key (`~/.ssh/github_test01`, which can push to Test01), despite Claude's rules. It could then send them anywhere: an allowed `node` or `npm` command can reach any host. Only the checks and the title check, in the sandbox, have no network. What limits the damage: the App and the `gh` token reach only this repo, the ruleset keeps everyone off `main` except by a merged PR, and the user can revoke the App key or the deploy key on GitHub. Closing the gap is two backlog items (the user's decision, 2026-11-19): "Run the runner's agent as its own Linux user", then "A credential broker for the runner".
  - Anyone else with the user's account on this machine can read `app.pem` too, and act as the App on this repo. Revoking the key on the App's page stops that.

## Tasks for the user

- **Before the builder's check 7, any time before this PR merges:**
  1. **Create the App** `JD-cookie-Agent` (done 2026-11-19, and installed on Test01 by the user's account) (GitHub → Settings → Developer settings → GitHub Apps → New GitHub App), as for release-please's App in `docs/devops.md`: no webhook, installable only on this account, with the permissions in "The App's token". Install it on Test01 only.
  2. **Save its key and client ID** (done 2026-11-19: the folder is mode `700`, both files `600`): generate a private key, save it as `~/.config/jd-cookie-agent/app.pem` with mode `600`, and write `APP_CLIENT_ID=<client id>` to `~/.config/jd-cookie-agent/app.env`.

  The builder checks both with `scripts/agent-run.sh check`, which makes a token and changes nothing (check 7).
- **Before the runner's first real run, after this PR merges at the latest:**
  3. **Qodo:** turn on "Allow GitHub bot reviews", and add release-please's App to the logins that aren't reviewed: `test01-release-please[bot]` (its login in GitHub's API), and `app/test01-release-please` (as `gh` shows it), since it's not known which form Qodo matches.
  4. **A ruleset for `main`** (Settings → Rules → Rulesets): require a pull request, and block force pushes and deletion, with no bypass. Then nobody, the App included, pushes to `main` except by merging a PR.

  The builder checks 4 with `gh api repos/<owner>/<repo>/rules/branches/main`, which must list `pull_request`, `non_fast_forward`, and `deletion`, and `gh api repos/<owner>/<repo>/rulesets/<id>`, which must show `"enforcement": "active"` and no `bypass_actors`. If the user's token can't read `bypass_actors`, the builder asks the user to confirm "Bypass list: empty" on the ruleset's page. Step 3 shows on the runner's first real PR: Qodo reviews it. The next release PR shows that Qodo still skips release-please.
- **After this PR merges, before part 3 (Q9):**
  5. **A second small ticket for a real run by hand:** pick a small backlog item other than 004, refine it with `refine-ticket`, and mark it `ready` as usual. Put its row above 004's in `docs/backlog/README.md`, since `claim next` takes the first free ready ticket in the table's order, in the same `ready` PR. Then, on `main`, check that `scripts/ticket.sh list` shows it before 004, and run `scripts/agent-run.sh` by hand (check 9). Ticket 004 stays kept for part 3's real run on Day 4.

## Implementation map

- `scripts/agent-run.sh` (new): one run, as in "Processing", and `check`. The credential helper is in it, as git configuration variables ("The App's token"), not a file of its own.
- `scripts/agent-run/build.md`, `fix-checks.md` (new): the agent's prompts.
- `scripts/agent-run/settings.json` (new): the agent's Claude permissions ("The agent"), with placeholders for the secret folders.
- `scripts/agent-token.sh` (new): makes the App's token ("The App's token"), and prints it only to a file descriptor the runner reads.
- `scripts/test/agent-run.test.sh` (new): the tests below. Run by a new `npm run test:scripts` at the root.
- `package.json` (root): a new script, `test:scripts`, and `check` extended to run it after the server's and the app's checks.
- `.github/workflows/ci.yml`: a third job, `scripts`, on `ubuntu-24.04`, following rule 5 like the other two: checkout, `setup-node` with Node 24 and the npm cache, `npm ci` at the root (the tests run the real commitlint, a root dev dependency, as `pr-title.yml` installs it), then `npm run test:scripts`. CI doesn't run the root `check` today: its jobs run the server's and the app's.
- `.husky/pre-commit`: `scripts` becomes a third part beside `server` and `app`. When `scripts/` has staged changes, it needs the root `node_modules` (or says to run `npm install` at the root, as it does for the others), links it into the snapshot, and runs `npm run test:scripts` there, on the staged content.
- `.gitignore`: `.agent/`, and `*.pem`, which the user added in their checkout on 2026-11-19, so no App key in a working tree is committed.
- `docs/devops.md`: a section on the runner: what it does, checking the setup, running it, following a run, and what `needs-help` means.
- `AGENTS.md`: a line in the table for the runner.

## Acceptance checks

Checks 1 to 6 are in `scripts/test/agent-run.test.sh`. It runs the runner against a scratch setup: a local bare repo as `origin`, holding a copy of the backlog with one `ready` ticket; stub `gh`, `claude`, and `curl` commands first on `PATH` (the `curl` stub answers the two token calls with a fake token of 520 characters, `ghs_` and two dots, as GitHub's are), which record how they were called and answer from fixture files, with lists long enough to need a second page; and an `npm` stub, in which `npm ci` links the repo's root `node_modules` into the clone (so the title check runs the real commitlint, with no network) and does nothing in `server/` and `app/`, and `npm run check` passes, fails, or hangs on cue. `AGENT_RUN_ORIGIN` points the clone at the bare repo. Each check passes when the script prints `ok N`, and CI runs it. The cases that need a real `bwrap` or a real TCP listener print `skip N` instead when `AGENT_RUN_IN_SANDBOX=1`. The other cases still run there: they use the `bwrap` stub, whose setup probe answers as a working sandbox would, and no runner code opens a listener. The reason for the skips: the runner's own checks run the root `check`, and so these tests, inside the sandbox, where a listener can't be opened (probed 2026-11-19: `EACCES`). They run in CI and in `npm run check` on the user's machine.

1. **No ticket:** with no `ready` ticket, a run claims nothing, calls `claude` 0 times, and logs `no ready ticket`.
2. **Build:** with one `ready` ticket, a run creates its claim branch on the bare `origin`, calls `claude` once with the build prompt, runs the check stub once, pushes the branch, and calls `gh pr create` with the label `agent-run` and the title from `.agent/pr.md`. The labels are created first when the `gh` stub says they don't exist.
3. **Check retries:** with the check stub failing every time, the run calls `claude` 3 times in all, then opens a draft PR with `needs-help`. The run folder has `base.txt`, `commits.bundle`, and `uncommitted.patch`: with the agent stub making one commit and leaving one new untracked file and one changed binary file, restoring them in a fresh clone of the bare `origin`, as "Stopping for help" says, gives the clone's tree exactly: both when the stop pushed the commit, and when the push was refused. With the agent stub making a merge commit, the restored history has the merge. With the agent stub writing `stop.md` and changing nothing, the folder has only `base.txt`, and restoring it gives the base. With an agent stub that ignores SIGTERM, its try ends at the kill time (shortened by the test). With a check stub that changes a tracked file and passes, the try fails. With a 70,000-character `stop.md`, output, and `pr.md` body, the draft's description is under 60,000 characters and starts with the reason and the run folder. With the check stub hanging, the try fails after the time limit (shortened by the test), and the next try runs. With it failing once, then passing, it opens a normal PR after 2 tries. With a `pr.md` title that commitlint rejects, the title counts as a failed check, and `gh pr create` is never called with it; with a good title, the real commitlint passes it (no stub). With the agent stub replacing `commitlint.config.mjs` in the clone by one that accepts every title and writes a file when loaded, a title only `main`'s config rejects still fails, and the file isn't written. With a commitlint stub that hangs, the title check fails after its time limit (shortened by the test). With the agent stub leaving an uncommitted change, the try fails before `npm run check` runs, and the fix prompt gets `git status`'s list.
   - **Stops before a PR:** with the agent stub writing `.agent/stop.md`, the run opens a draft PR with `needs-help` and `stop.md` in its description, in the one `gh pr create` call, and posts no comment. With the `gh`/push stub refusing a push that changes `.github/workflows/`, it opens the draft PR from the branch as it is on `origin`, and the description names the saved files.
   - **Bad agent output:** with `.agent/pr.md` left over from an earlier try and the agent stub writing nothing, the try fails. With the build try writing `pr.md`, the checks failing once, and the fix try writing `pr.md` again, the PR gets the fix try's title, and the fix prompt held the build try's `pr.md`.
4. **Crash, lock, and open PRs:**
   - a claim branch with no PR gets a draft PR with `needs-help`, and no `claude` call
   - a claim branch whose PR was merged, and one whose PR was closed, get no PR and no `claude` call, and the run goes on to `ticket.sh list`
   - a claim branch with another agent's name in its `Claimed-By` trailer is never touched. The agent name is `runner-` and the first 12 characters of the machine id (a stub `/etc/machine-id` path in the test)
   - a second run while the first holds the lock exits 0 at once
   - a claim branch with an open PR, with `needs-help` or without, gets no `claude` call, no comment, and no new claim, and the run logs `PR #<n> is open`
5. **The token:** with a test key made by `openssl genrsa` and the `curl` stub:
   - the JWT the stub receives verifies with the key's public half (`openssl dgst -sha256 -verify`), its `iss` is the client ID, and `exp - iat` is 600
   - the fake 520-character token reaches the `gh` stub as `GH_TOKEN`
   - the credential helper, asked by `git credential fill` for `https://github.com` in the runner's environment, answers `username=x-access-token` and the token, and the clone's `.git/config` has no `credential.helper`. (A push to a local bare `origin` never asks a credential helper. Probed 2026-11-19, so the helper is tested on its own.)
   - with the clock moved past the hour between two agent tries (a stub `date`), the `curl` stub sees a second token request before the push
   - the token's text appears in no log file, and in no command line the stubs record, `claude`'s included, and `claude`'s environment has no `GH_TOKEN`
   - with the stub answering `401`, the run logs the failed step and exits 1, with no `claude` call
   - with `app.pem` readable by others (mode `644`), `agent-run.sh check` and a run both stop, with no `claude` call
6. **The agent's limits:** with the `claude` stub recording its arguments and environment, and a `bwrap` stub recording its own:
   - `claude` gets `--settings` with a file filled in from the one beside the running script, not the clone's: with the agent stub rewriting the clone's `scripts/agent-run/settings.json` in try 1, try 2 gets the same settings as try 1. That file allows `WebSearch` and exactly the listed `WebFetch` domains, and denies `Read` and `Edit` of the three secret folders
   - `npm run check` and the title check run with no `VALKEY_URL` in their environment, also when the test sets one for the runner, and with `AGENT_RUN_IN_SANDBOX=1`
   - with `XDG_RUNTIME_DIR` unset, a run exits 1 with its message, and calls `claude` 0 times
   - with a real `bwrap`, when the machine has one, the whole `npm run test:scripts` passes inside it, as the runner runs it, with the listener cases skipped
   - `npm run check` and the title check run only through `bwrap`, with `--ro-bind / /`, the clone bound writable, `--tmpfs` over the three secret folders and `/tmp`, `--unshare-pid --proc /proc`, `--unshare-net`, and no `GH_TOKEN` or `GIT_CONFIG_COUNT` in their environment
   - with `XDG_CONFIG_HOME` set to a scratch folder outside `$HOME/.config`, the `bwrap` masks and the settings' denied folders are the ones under it
   - every push the runner makes after the agent's first run has `core.hooksPath=/dev/null`: a `pre-push` hook in the clone's `.husky/` that writes a file doesn't run. The claim's push, in `scripts/ticket.sh`, runs before any agent run, on `main`'s hooks
   - with a real `bwrap`, when the machine has one (skipped in CI if it doesn't), a check stub that tries to read a file under a fake secret folder fails to read it, and one that connects to a listener the test started on `127.0.0.1`, which it reached from outside first, fails. `agent-run.sh check`'s two sandbox checks pass with the real `bwrap`, and fail with a `bwrap` stub that runs its command directly, so it hides no file and has the host's network
7. **The real setup:** on the user's machine, after tasks 1 and 2, `scripts/agent-run.sh check` passes every check, including making a token, and nothing changes on GitHub. The builder records its output, without the token, in "Delivery and review".
8. `npm run check` passes locally and in CI, and `docs/devops.md` has the runner's section.
9. **The real run by hand** (after this PR merges, with the user; Q9): with tasks 1 to 5 done, and a small ticket `ready` above 004 in the backlog, `scripts/agent-run.sh` on `main` claims that ticket, and not 004, builds it with the real `claude`, gets the checks green, and opens a PR as `jd-cookie-agent[bot]`, or stops with a draft PR and `needs-help`. Shown by the PR and the runner's log. Qodo reviews the PR, which shows task 3 works, and the user takes it through review and merges, since rounds are part 2's. It happens after this PR merges, so what happened goes in a follow-up docs PR to this feature's "Delivery and review", as ticket 003's last checks did in PR #12: who opened the PR, the tries and checks, Qodo's findings, and where the user had to step in.

## Readiness review

Refined 2026-11-19 by Claude Code (claude-opus-5-5), as the whole of "An agent that builds ready tickets on a timer", then split after review round 2. What follows is the record of the whole until the split, kept here, in the first part. This part hasn't been reviewed on its own since: that's the next round.

- **Goal, restated (the whole):** for the user, who wants ready tickets built without starting a session for each. A script, started every 15 minutes by a systemd user timer, does one step per run: claim and build a ready ticket, get the checks green, open the PR, then run a fix round on each Qodo review, up to set limits, and stop with `needs-help` when stuck. The user still marks tickets ready and merges.
- **Goal, restated (this part):** for the user: one command, run by hand, that claims and builds the next ready ticket and opens its PR as the App, with the checks green or a draft PR asking for help.
- **The split** (the user's decision, 2026-11-19): after round 2 the doc was about 410 lines, and failed Definition of Ready item 4 ("Fits one PR … small enough for one agent session"). Split into three vertical slices: this one, then [the review rounds](agent-review-rounds.md), then [the timer](agent-timer.md). Each part keeps its own sections and decisions. This one changed in the split: a run that finds its PR open does nothing (the review step is part 2); the prompts and settings are read from beside the running script (the copy in `bin/` is part 3's); the setup checks moved here, as `agent-run.sh check`, from `agent-timer.sh check`; label creation moved here from the timer; and this part's real check is `agent-run.sh check` with the real key, since ticket 004 is kept for Day 4's real run in part 3.
- **Is it needed:** not built: `scripts/` has only `ticket.sh`, and no timer or runner is in the repo or the docs. Overlaps: "Code reviews by our own agents" is a separate row, out of scope here. No open PRs. Never dropped: the backlog history has no runner or scheduled build.
- **Facts checked while refining:**
  - `scripts/ticket.sh claim` pushes the claim branch itself, with a `Claimed-By:` trailer, and has exit code 5 for a ticket withdrawn during the claim. Added to the build step.
  - The runner posted as the user, so its own round comments and replies would have come back to the agent as the owner's comments. Fixed by the user's choice of a GitHub App (Q1), with the runner's comments told apart by author. Also added: the owner's PR comments, which the doc had left out, and a marker naming the head commit of each round.
  - `main` has no ruleset (`gh api repos/JD-cookie/Test01/rules/branches/main` returns `[]`), so the App's contents permission could push to it.
  - GitHub's App installation tokens are about 520 characters, with dots, since 2026-10-02. The runner treats the token as opaque, and check 5 uses a fake token of that shape.
  - `next-ticket` step 4 merges `main` into the branch during review (part 2).
  - The labels `agent-run` and `needs-help` don't exist in the repo yet.
  - `gh pr edit` fails in `gh` 2.46, so labels are changed with `gh api`.
  - CI doesn't run the root `check`. Added: a `scripts` CI job and the pre-commit hook.
  - `systemd-analyze` (probed): `--user verify` fails without a login session, and `verify` exits 0 on unknown keys (part 3).
  - The `gh` token expires 2027-01-11: a known gap.

- **Definition of Ready** (this part, after the split; to be confirmed in its own review round):
  1. pass: the Summary says who it's for, what changes, and what doesn't
  2. pass: see "Is it needed"
  3. pass: an out-of-scope list, naming parts 2 and 3
  4. pass: scripts, one CI job, and docs, in one PR. It ships alone: a run by hand builds a ticket into a PR
  5. pass: every label, comment text, file path, exit code, and App permission is given
  6. pass: the App, its key, Qodo's settings, and the ruleset, each with when and how the builder checks it
  7. pass: checks 1 to 6 run against stubs and a bare `origin`, with `ok N` as the result, check 7 is the real setup, and check 9 is a real build by hand with the real `claude` and GitHub, on a second small ticket, after the merge (Q9)
  8. pass: each rule, in "Security and configuration"
  9. pass: who triggers it, the failure modes, the token's handling, the known gaps
  10. pass: Q1 to Q9 are answered and recorded
- **Questions and answers** (all three parts):
  - Q1: the runner's own GitHub identity, as a GitHub App → yes (2026-11-19). The user made `JD-cookie-Agent` and turns on Qodo's bot reviews, skipping release-please by login.
  - Q2: one agent round on every commit Qodo reviews, even with no findings → yes (part 2).
  - Q3: probe `claude -p` under `systemd-run --user` → yes: it worked (part 3).
  - Q4: no Workflows permission for the App, and `needs-help` for a ticket that changes a workflow → yes.
  - Q5: a ruleset on `main` (a PR required, no force pushes or deletion, no bypass) → yes, a task for the user.
  - Q6: keep the App key from the agent → the user asked how; a probe showed `claude` can't run in `bwrap` here (AppArmor blocks its network). Options: (A) the agent as its own Linux user, (B) Claude's permission rules plus the checks in `bwrap`, or a credential broker, which the user suggested. → B now, with backlog rows for A and the broker (2026-11-19).
  - Q7: web access for docs → `WebSearch`, and `WebFetch` only for documentation sites, `node_modules` first (2026-11-19).
  - Q8: round 2's reviewers, after a tie (14 kept each) → both again.
  - Naming: the runner's local folders, units, lock, and marker → `jd-cookie-agent`, like the App (the user's request, 2026-11-19).
  - Split → yes, into three parts (2026-11-19).
  - Q9: a real run of this part by hand, before part 3, needs a `ready` ticket other than 004 → yes (2026-11-19): a second small ticket, refined and marked ready after this part merges, and run by hand (task 5, check 9).
- **Probes:** `systemd-analyze verify` (part 3); `bwrap` hiding files, blocking the network, and running the server's tests (see "The agent"); `claude -p` in a systemd user service (part 3).
- **Review round 1 (the whole):** Codex (gpt-6.1-sol) and opencode (ollama-cloud/kimi-k3.1-pro), run separately. Both restatements match the goal. They made 28 findings, 14 each. 7 problems were found by both, so 21 in all. All were kept: 19 fixed in the doc, 2 turned into questions (Q6, Q7).
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
- **Review round 2 (the whole):** Codex (gpt-6.1-sol) and opencode (ollama-cloud/kimi-k3.1-pro), both at the user's choice after a tie. Both restatements match. 29 findings (Codex 14, opencode 15), 6 found by both, so 23 problems. 28 kept, all fixed in the doc, and 1 dropped.
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

  The check numbers in these two rounds are the whole doc's, before the split.
- **Review round 3 (this part, after the split):** Codex (gpt-6.1-sol) and opencode (ollama-cloud/deepseek-v4-pro, the candidate with no rows yet, since this part is its own refinement now), both at the user's choice. Both restatements match. 13 findings (Codex 9, opencode 4), none found by both. All 13 kept: 12 fixed in the doc, 1 turned into a question (Q9).
  - Codex: the network check, a connection to `127.0.0.1` failing, also fails with no listener, so it proved nothing. Fixed: a listener that answers outside first, and `--unshare-net` (probed), so the sandbox's network doesn't rest on AppArmor alone.
  - Codex: with a different `XDG_CONFIG_HOME`, the key moved out from under the sandbox's masks and Claude's denied folders. Fixed: both are resolved at run time, with a test.
  - Codex: a crash between opening the draft PR and commenting left a draft that never said why, since a later run skips an open PR. Fixed: the reason is in the draft's description, in one call.
  - Codex (needs a run): commitlint, given a copy of `main`'s config outside the repo, can't resolve its `extends`. Probed: `Cannot find module "@commitlint/config-conventional"` for every title. Fixed: the copy goes in the clone's `.agent/`, probed to pass a good title and fail a bad one.
  - Codex: the title check had no time limit. Fixed: 2 minutes.
  - Codex: the checks ran on the working tree, so a fix the agent didn't commit could pass them and not be pushed. Fixed: a clean tree is required first.
  - Codex: the patch test didn't say what to apply the patches to once the commits were pushed. Fixed: `base.txt`, and the test covers a pushed and a refused stop.
  - Codex: check 6 said every push skips hooks, but the claim's push, in `ticket.sh`, runs `main`'s. Fixed: only pushes after the first agent run.
  - Codex: the config test couldn't fail: the sandbox stops the write whichever config runs. Fixed: the clone's config accepts every title, and a title only `main`'s rejects must still fail.
  - opencode: no check runs a real build in this part. Turned into Q9; Definition of Ready item 7 now names the gap.
  - opencode: `.agent/` is emptied before each try, so a fix try lost the build try's `pr.md`. Fixed: every try writes `pr.md`, and the fix prompt gives the last one.
  - opencode: the credential helper wasn't defined anywhere. Fixed: git configuration variables in the runner's environment, never in the clone's config, with a test.
  - opencode: the `scripts` CI job and the pre-commit hook didn't install the root `node_modules` that the real commitlint needs. Fixed: `npm ci` at the root in the job, and `scripts` as a third part in the hook.
  - Dropped: 0.
- **Review round 4 (this part):** Codex (gpt-6.1-sol) and opencode (ollama-cloud/deepseek-v4-pro), both at the user's choice. Both restatements match. opencode checked round 3's fixes and found them holding. 11 findings (Codex 6, opencode 5), none found by both. All 11 kept and fixed in the doc; one of them (Q9 left open) needs the user's answer.
  - Codex (needs a run): the root `check` runs the runner's tests, and the runner runs the root `check` in the sandbox, where the tests' TCP listener can't open. Probed: `EACCES` (a `bwrap` inside the sandbox does work). Fixed: those cases skip under `AGENT_RUN_IN_SANDBOX=1`, and a check runs the whole suite in a real `bwrap`.
  - Codex: the clean-tree rule ran only before the checks, and the checks run the agent's code. Fixed: clean and at the same `HEAD` after them too.
  - Codex: `format-patch` leaves out merge commits, which part 2's rounds make. Probed: 2 patches and no merge; a bundle kept it. Fixed: `commits.bundle`.
  - Codex (needs a run): `timeout 45m` doesn't kill an agent that ignores SIGTERM. Probed: it kept running until an outer kill. Fixed: `--kill-after=1m`.
  - Codex: only the output was cut to fit GitHub's limit on the description. Fixed: the whole description stays under 60,000 characters, the reason first.
  - Codex: item 10 said every question was answered, with Q9 open. Fixed: item 10 says "not yet".
  - opencode: the root `package.json` wasn't in the implementation map. Fixed.
  - opencode: `VALKEY_URL` from the user's shell would reach the checks, and the Valkey tests would fail with no network. Fixed: removed, with a test.
  - opencode: the lock had no rule for an unset `XDG_RUNTIME_DIR`. Fixed: exit 1 with a message.
  - opencode: the tests stubbed `npm run check` but didn't say how the real commitlint gets into the clone. Fixed: the `npm` stub's `npm ci` links the root `node_modules`.
  - opencode (needs a run): `git am` fails on an empty patch, and an empty one was allowed. Probed: exit 128. Fixed: files that aren't needed aren't written, and restoring checks for each.
  - Dropped: 0.
- **Q9 answered** (2026-11-19), after round 4: yes, a second small ticket for a real run by hand, after this part merges and before part 3 (task 5, check 9). Definition of Ready items 7 and 10 pass.
- **Review round 5 (this part):** Codex (gpt-6.1-sol) only, at the user's choice, asked for findings that would make a build wrong or need a question. The restatement matches. 2 findings, both kept and fixed in the doc.
  - Codex: a run's setup check opens a TCP listener, so every runner test, not just the listener cases, would fail inside the sandbox. Probed: inside `bwrap --unshare-net`, `/proc/net/dev` lists only `lo`, also nested, while `/sys/class/net` shows the host's interfaces. Fixed: the setup's network check reads `/proc/net/dev`, and only check 6's listener case needs a listener.
  - Codex: `claim next` takes the first ready ticket in the table's order, so check 9 would claim 004. Fixed: task 5 puts the second ticket's row above 004's, and checks `ticket.sh list` first.

## Decisions made for this ticket

Decided by the user on 2026-11-18:
- **One step per run, with the state in GitHub.** A reboot or a crash loses nothing, and every run leaves a log.
- **Retry limit:** 3 tries to get the checks green. Then `needs-help`, and the runner waits for the user.
- **Claude Code (`claude -p`) in its own clone.** It never merges, never pushes (the runner does), and never touches `server/.env` or the development database.
- **One ticket at a time.**
- **Not GitHub Actions:** it would need a Claude API key as a secret in a public repo, and it couldn't use the user's Claude login. (Part 3 has the decision on the timer.)
- **No notifications outside GitHub:** GitHub's own are enough now that the runner is the App. A push service such as ntfy was the other option, but it's an outside service.

Decided by the user on 2026-11-19:
- **The runner is a GitHub App, `JD-cookie-Agent`.** Its PRs and comments are its own, so the user gets notified and can review them, and its tokens last an hour and reach only this repo. A second "machine user" account was the other option: Qodo would review it with no change, but its token may not be limited to one repo. With the App, the user turns on Qodo's bot reviews and skips release-please by its login.
- **No Workflows permission for the App.** A PR built by the runner can't change CI, the most sensitive files in a public repo (rule 5). A ticket that changes a workflow stops with `needs-help`, and the user finishes it.
- **A ruleset on `main`:** a pull request is required, and force pushes and deletion are blocked, with no bypass. The App's contents permission would otherwise let it push to `main`. The user sets it up (see "Tasks for the user").
- **Keeping credentials from the agent, for now:** Claude's permission rules deny the secret folders, the checks run in `bwrap` with no network, the token is never in the agent's or the checks' environment, and pushes run no hooks. The agent can still read the files with an allowed command: a known gap. The other options, both for later backlog items: the agent as its own Linux user (the OS hides every credential, but it needs `sudo` once and a `claude login` as that user), and a credential broker, a small service as another user that holds the key and does only the runner's actions (it hides the App key, but not the user's `gh` token or deploy key, and it's the most new code). `claude` can't run in `bwrap` on this machine, so the sandbox can't hold the agent itself.
- **Docs on the web:** `WebSearch`, and `WebFetch` for the documentation sites in "The agent". Agents need API docs while building, and `app/AGENTS.md` requires Expo's. An open `WebFetch` would add any site's text as input, and with the known gap above, a way to send a credential out.
- **Split into three parts:** this one, the review rounds, and the timer, each its own ticket and PR.
