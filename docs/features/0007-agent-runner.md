# A runner that builds a ready ticket into a PR

Status: implemented: part 1 of 3, the runner run by hand. The other two parts are in the backlog: [the review step](../backlog/agent-review-rounds.md), which adds fix rounds on Qodo's findings, and [the timer](../backlog/agent-timer.md), which starts the runner every 15 minutes. Each edits this doc when it's built.

## Summary

Without it, an agent builds a ticket only when the user opens a session and asks. The **runner**, `scripts/agent-run.sh`, does it instead. The user runs it by hand, and one run does the next step for the runner's own ticket:
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
- Running in GitHub Actions or the cloud (the reasons are in the ticket, linked in "Changes").
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

The runner pushes, opens PRs, and comments as the App `jd-cookie-agent[bot]` (see "The App's token"). So the user gets GitHub's notifications for them, and can review its PRs like anyone else's. Qodo reviews them once the user has turned on bot reviews in Qodo, with release-please's App on Qodo's skip list (see "Setup"): Qodo didn't review release-please's PR #4, because bot reviews were off.

## Processing

### One run

`scripts/agent-run.sh` with no arguments does one run. `scripts/agent-run.sh check` does only the checks in "Checking the setup". It works in its own clone, `${XDG_DATA_HOME:-$HOME/.local/share}/jd-cookie-agent/repo`, and never in the user's checkout. It clones `origin` there if that clone doesn't exist. Its agent name for claims is `runner-<id>`, where `<id>` is the first 12 characters of `/etc/machine-id`, which is unique to each installed system, unlike a short host name.

The agent can edit everything in the clone, so nothing the runner trusts is read from it: the runner's prompts and Claude settings come from the folder the running script is in (`scripts/agent-run/` beside it), and the commitlint config from `main` (see the title check). Run by hand, that's the user's checkout, which the agent never touches. Part 3 makes the timer run a copy instead.

1. **Lock.** It takes `flock -n` on `${XDG_RUNTIME_DIR}/jd-cookie-agent.lock`. If another run holds it, it exits 0. If `XDG_RUNTIME_DIR` isn't set, or the lock file can't be opened, it exits 1 with a message to run it from a login session: a login session and a systemd user service both have it (probed for the service, see part 3). The lock is per machine. A runner on a second machine has another agent name, so it only works on its own claims (step 2), and the two never touch the same PR.
2. **Find its work.** It looks only at its own tickets: branches on `origin` whose claim commit, the first commit after `main` on the branch, has the trailer `Claimed-By: runner-<id>` with its own agent name. For each one, it looks up the branch's PRs in every state (`gh api --paginate 'repos/<owner>/<repo>/pulls?state=all&head=<owner>:<branch>'`):
   - **A merged or closed PR:** that ticket is over. Skip it. The user deletes its branch when they like; until then, the claim keeps other agents off it.
   - **An open PR:** it's in review, with the user (and, once part 2 is built, with the review step). Log `PR #<n> is open` and exit. If the PR has no `agent-run` label, the call that adds the labels failed when it opened: the run adds `agent-run` first, and `needs-help` too if the description starts as a stop's does (`**The runner stopped for help.**`). A PR that has `agent-run` is left as it is, so a `needs-help` the user removed isn't added again.
   - **No PR:** an earlier run died while building, for example in a reboot, or opening the PR failed after the push. Stop for help, as in "Stopping for help": if the clone still has the branch with commits that `origin` doesn't, they're saved and pushed; then the draft PR opens, with the reason "A run stopped while building this ticket. Its work so far is on this branch." It's the same every time it runs, so a run that dies partway through it is finished by the next.
   - **None of its tickets has an open PR:** if `scripts/ticket.sh list` shows a free `ready` ticket, build step (below). If not, log `no ready ticket` and exit.

   Only one ticket is in progress at a time: the runner doesn't start a new one while any of its PRs is open, `needs-help` or not.
3. **A token for each phase.** It makes a new App token (see "The App's token") right before each group of GitHub calls and pushes: when it finds its work, after each agent run, and before each push. Each token lasts an hour, and a run can last longer: three agent tries of up to 45 minutes each.

### Build step

1. In the clone: `git fetch`, then switch to a clean `main` at `origin/main`, and delete every other local branch: the clone is the runner's own, and what matters is on `origin`. A local branch left by a run that failed would make the next claim fail. The clean is `git clean -ffdx`, so ignored files go too (`npm ci` reinstalls `node_modules` anyway), and it empties `.agent/`. Nothing an earlier ticket's agent left, such as a hook in `.husky/_`, which husky's own `.gitignore` ignores, or an old `pr.md`, reaches this ticket's claim. Then `npm ci` at the root and in `server/` and `app/`, so the hooks and checks run as in CI. Then it writes the clone's `.git/config` (see "The agent").
2. `scripts/ticket.sh claim next "runner-<id>"`. Its exit codes (see `scripts/ticket.sh`):
   - **0:** claimed. The script has already pushed the claim branch, `NNNN-slug`, whose commit has the trailer `Claimed-By: runner-<id>`.
   - **3:** no free ticket. Exit 0.
   - **5:** claimed, but the ticket was withdrawn or changed on `main` meanwhile. Stop, as in "Stopping for help", with the script's message.
   - **anything else (2, 4):** log the message and exit 1. If the claim reached `origin` after all, the next run finds the branch with no PR, and stops for help.
3. **Build**, try 1 of 3: run the agent with the build prompt (see "The agent"). It follows the `next-ticket` skill's step 2, and commits, but doesn't push. If it wrote `.agent/stop.md`, stop, as in "Stopping for help", with `stop.md` as the comment. If it hit Claude's usage limit, stop at once (see "Claude's usage limit"), here and in every fix try.
4. **Checks:** first, the clone must have no changes the agent didn't commit: `git status --porcelain` lists nothing (`.agent/` is ignored). If it lists something, that's a failed try, with the list as its output, so the checks always test what gets pushed. Then the runner itself runs `npm run check` in the clone, in the sandbox (see "The agent"), with a time limit of 20 minutes (`timeout --kill-after=1m 20m`). A check that runs out of time is a failed try. The runner doesn't take the agent's word for it. After the checks and the title check, the clone must still be clean and at the same `HEAD`: the checks run code the agent wrote, which could change a tracked file and test that instead. If not, that's a failed try too.
   - **Pass:** go to 5.
   - **Fail:** run the agent again with the fix prompt and the check's output (the last 200 lines), then check again. That's try 2, then try 3.
   - **Still failing after 3 tries:** stop, as in "Stopping for help", with "The checks still fail after 3 tries." and the last 200 lines of output.

   The tries are counted in the run itself. They can't repeat across runs: a run that dies mid-build leaves a branch with no PR, and the next run stops for help.
5. **The title:** the agent writes `.agent/pr.md`: the first line is the PR's title, the rest is its body, as `next-ticket` step 3 describes. The runner checks the title with commitlint and `main`'s config, as `pr-title.yml` does with the base branch's: after the agent's run, `git show origin/main:commitlint.config.mjs > .agent/commitlint.config.mjs` in the clone, then `printf '%s\n' "$title" | ./node_modules/.bin/commitlint --config .agent/commitlint.config.mjs`, in the sandbox, with a time limit of 2 minutes (`timeout --kill-after=10s 2m`). The copy goes in the clone, not the run's folder, because commitlint resolves the config's `extends` (`@commitlint/config-conventional`) from the config's own folder: probed 2026-11-19, a copy in a folder outside the repo fails every title with `Cannot find module "@commitlint/config-conventional"`, while a copy in `.agent/` of a checkout passes a good title (exit 0) and fails a bad one (exit 1), in `bwrap`. commitlint itself, in the clone's `node_modules`, is JavaScript the agent could have changed, so the check gets no token and no network. At worst it passes a bad title, and `pr-title.yml` fails it in CI. If it fails, that's a failed check, with commitlint's output, and goes to the fix prompt like the others.
6. **Push and open the PR:** push the branch, then open the PR with that title and body in one API call (`gh api -X POST repos/<owner>/<repo>/pulls`), and add the label `agent-run` in a second (`repos/<owner>/<repo>/issues/<n>/labels`). Every GitHub call is `gh api`: `gh pr edit` fails in the installed `gh` 2.46, and one kind of call keeps the tests' `gh` stub small. The runner creates the labels `agent-run` and `needs-help` when it first needs them and they don't exist (`gh label create`, with the App's token). Neither exists in the repo today. A push that GitHub refuses because the branch changes `.github/workflows/` stops the build, as in "Stopping for help". If opening the PR fails after the push, the run exits 1, and the next run finds the branch with no PR.

### Stopping for help

Whenever the runner stops for the user, it does the same. In this part, that's always before a PR exists. Part 2 adds the same stop for an open PR.
1. **Save the work.** In the run's folder, `${XDG_STATE_HOME:-$HOME/.local/state}/jd-cookie-agent/runs/<UTC time>/`, it writes:
   - `base.txt`: the commit the saved work starts from: the merge base of `HEAD` and `origin/<branch>` if the branch is on `origin` (which is `origin/<branch>` itself unless it moved on while the clone stayed behind), or else the `main` commit the claim started from. If `HEAD` shares no commit with either, because its history was rewritten, it's `none`, and the bundle holds `HEAD`'s whole history.
   - `commits.bundle`: `git bundle create commits.bundle <base>..HEAD`, only if `HEAD` has commits after the base (git refuses an empty bundle), or `git bundle create commits.bundle HEAD` when there's no base. A bundle, not `format-patch`, because `format-patch` leaves out merge commits, and part 2's rounds merge `main` (probed 2026-11-19: a range with a merge gave 2 patches and no merge; the bundle kept the merge).
   - `uncommitted.patch`: from `git add -A` and `git diff --cached --binary HEAD`, then `git reset -q`, only if there's a change. `git add -A` takes untracked files too, except ignored ones, and `--binary` keeps binary files.

   To restore in a fresh clone: check out `base.txt`'s commit (unless it says `none`); if `commits.bundle` exists, `git fetch <run folder>/commits.bundle HEAD` and `git checkout FETCH_HEAD`; if `uncommitted.patch` exists, `git apply` it. Files that weren't needed aren't written, since `git am` fails on an empty patch (probed: "Patch format detection failed", exit 128). That works whether or not step 2 pushes the commits afterwards.
2. **Push** the branch if it has commits that `origin` doesn't, unless the reason for stopping is that GitHub refused the push (a workflow change). Then `origin` keeps only what's there, and the PR's description names the saved files.
3. **Open a draft PR** from the branch with the labels `agent-run` and `needs-help`, with the title from `.agent/pr.md` if it passes the title check, or else `chore(repo): build ticket NNNN-slug`. Its description holds everything the user needs: the reason, the run folder's path, and the names of the saved files first, then the last 200 lines of output if there are any, then the body from `pr.md` if there is one. The whole description is kept under 60,000 characters, below GitHub's limit of 65,536: the reason is cut to 5,000 if it's longer, and the output and the body are cut, from their start, to fit what's left, with a line that says so. The run's folder keeps them whole. The title, the description, and the draft state are one call, so a crash leaves either no PR, which the next run handles as above, or one whose description says why. The labels are a second call: a crash between the two leaves a PR without its labels, and the next run adds them back ("One run", step 2).

### The agent's files

`.agent/` in the clone is git-ignored. The runner empties it before each agent run, so an old file can't pass for a new one. After the run, it checks what the step needs. A missing or invalid file counts as a failed try:
- `pr.md`: a non-empty first line, and a body (after the title) whose first non-blank line is exactly `Ticket: NNNN-slug (docs/tickets/NNNN-slug.md)`, as `next-ticket` step 3 says. Every agent run writes it, the fix tries included: the fix prompt gives the last `pr.md`, to keep or change.

### The agent

Each run of the agent is a fresh `claude -p` process in the clone, with no MCP servers (`--strict-mcp-config`), a time limit of 45 minutes (`timeout --kill-after=1m 45m`: without `--kill-after`, a process that ignores SIGTERM keeps running, probed 2026-11-19), and its output saved to the run's log. Its permissions:
- **Allowed:** reading files, editing files in the clone, and these shell commands: `npm`, `node`, `npx`, `git status`, `git diff`, `git log`, `git show`, `git add`, `git mv`, `git rm`, `git commit`, `ls`, `cat`, `grep`, `find`, `head`, `tail`, `wc`, `mkdir`.
- **Denied:** `git push`, `gh`, `curl`, `wget`, and Claude's web tools beyond those below. The runner script does every push and every GitHub call itself, so the agent can't change GitHub with a token. These are Claude's tool rules, not a network limit: an allowed `node` or `npm` command can still reach any host (see "Known gaps").
- **Docs on the web** (the user's decision, 2026-11-19): `WebSearch`, and `WebFetch` only for these documentation sites: `docs.expo.dev`, `reactnative.dev`, `nodejs.org`, `developer.mozilla.org`, `fastify.dev`, `www.typescriptlang.org`, `docs.github.com`, `docs.npmjs.com`, `www.npmjs.com`, `sqlite.org`, `valkey.io` (as `WebFetch(domain:<site>)` rules). `app/AGENTS.md` requires the versioned Expo docs before code that touches Expo's APIs. The prompts say to look in `node_modules` first: the docs, type definitions, and READMEs of the exact installed versions. A fetch outside the list is refused, and the run log shows it, so the list can grow from what's missing.
- **Secret folders:** Claude's permission rules deny `Read` and `Edit` of the three secret folders (see the sandbox below). `settings.json` names them as placeholders, `{{APP_CONFIG}}`, `{{GH_CONFIG}}`, and `{{SSH}}`; the runner fills in the resolved paths in a copy in the run's folder, and passes that copy. These rules are enforced by Claude Code, not by the OS: an allowed `node -e` can still read the files (see "Known gaps").

The permissions are in `scripts/agent-run/settings.json`, read from the runner's own folder, never from the clone, filled in again before every try, and passed with `--settings`, so the agent can't change them for its next try: neither the clone's copy nor the filled one in the run's folder counts. They're reviewed like code. Tools not allowed there are refused, since `claude -p` has nobody to ask.
- **No token:** the runner starts `claude`, `npm run check`, and the title check with `GH_TOKEN` and the credential helper's variables removed from their environment (`env -u GH_TOKEN -u GIT_CONFIG_COUNT …`; see "The App's token"), and also without `VALKEY_URL` (below). Inside the sandbox it sets `AGENT_RUN_IN_SANDBOX=1`, so the runner's own tests know where they are (see "Acceptance checks").
- **The checks in a sandbox:** `npm run check` runs code the agent wrote, so the runner runs it in `bwrap` (bubblewrap): the whole file system read-only except the clone (but not its `.git`), `/tmp` (a private `tmpfs`), and the npm cache; empty folders over the secret folders; its own process list (`--unshare-pid --proc /proc`); and its own empty network namespace (`--unshare-net`). The secret folders are resolved when the runner starts: `${XDG_CONFIG_HOME:-$HOME/.config}/jd-cookie-agent`, `${GH_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/gh}`, and `~/.ssh`, so a different `XDG_CONFIG_HOME` moves the masks with the key. Probed 2026-11-19: reading a hidden file through another process, `/proc/<pid>/root/…`, was refused even without `--unshare-pid` ("Permission denied"), but the machine's processes were visible, which `--unshare-pid` hides. Probed 2026-11-19: inside such a sandbox, `app.pem`, `~/.config/gh/hosts.yml`, and `~/.ssh/github_test01` couldn't be read, the home folder couldn't be written, and the server's tests passed (23 of 23, Valkey's skipped). Ubuntu's AppArmor profile for `bwrap` also refuses every network socket inside it ("failed to open socket: Permission denied"), but `--unshare-net` doesn't depend on that profile. Probed 2026-11-19: with `--unshare-net`, the sandbox has only its own `lo`, and a listener on the host's `127.0.0.1`, which answered from outside, couldn't be reached from inside. The AppArmor profile is also why the agent itself can't run in `bwrap`: `claude` couldn't reach its API there (`EAI_AGAIN`).
- **No hooks on push:** every git command the runner runs in the clone, its pushes included, has `-c core.hooksPath=/dev/null -c core.fsmonitor=false`. The agent can edit `.husky/`, and a `pre-push` hook it added would otherwise run while the token is in the environment.
- **The clone's `.git/config`:** the agent can edit it too, for example with an `insteadOf` rewrite or a push URL that sends a push somewhere else, or an include. So the runner writes `.git/config` and `.git/info/exclude` from scratch, with only `origin` and husky's hook path (`.husky/_`, for the agent's own commits): at the start of every run, after `npm ci`, after every agent run, before the push, and before a stop for help. It writes them, not a saved copy, since the agent could edit a copy too. In the sandbox, the clone's `.git` is mounted read-only, so the checks can't change it either.
- **The token only when it's needed:** the runner drops the token and the credential helper from its environment after the claim, and makes a new one only to push and open the PR, or to stop for help. The agent's runs and the checks happen without it. Commit hooks still run, for the agent's commits. The claim's push, inside `scripts/ticket.sh`, comes before any agent run, on a clean `main`, so its hooks are `main`'s, which the user merged.
- **Valkey:** the agent's checks run without `VALKEY_URL`, removed from their environment even if the user's shell sets it (the server's Valkey tests run only when it's set, and the sandbox has no network to reach Valkey), so the Valkey tests are skipped there, as `AGENTS.md` describes. CI runs them with a Valkey service on every push.

The prompts live in `scripts/agent-run/` as Markdown files (`build.md`, `fix-checks.md`), with placeholders the runner fills in. Each one says:
- follow `AGENTS.md` and the `next-ticket` skill
- don't push, and don't touch `server/.env` or `server/data/`
- if the design doc is wrong or something needs the user's decision, write that to `.agent/stop.md` and stop. The runner then stops for help, with `stop.md` as the reason.

### Claude's usage limit

The agent runs on the user's Claude login (see "Security and configuration"), so it shares the user's 5-hour and weekly usage limits with the user's own sessions. Once a limit is reached, each `claude -p` run ends at once without doing the work. Without a rule for it, all 3 tries would fail in seconds, and the draft PR would wrongly say the checks failed.

So after each agent run, the runner checks for the limit: `claude` exited non-zero, and one of the last 20 lines of its output matches one of the patterns in `LIMIT_PATTERNS`, a constant at the top of `agent-run.sh` (case-insensitive: `usage limit reached`, `hit your limit`, `limit reached.*resets`). If so, it doesn't try again: it stops, as in "Stopping for help", with the reason "Claude's usage limit was reached during try N of 3:" and the matching line, which says when it resets, then "The work so far is on this branch." The user finishes the ticket, or waits for the reset. Both conditions are needed because the agent's own output can contain the same words (the repo has a rate limiter), and a run that exits 0 did its work.

Not probed: the exact text and exit code of `claude -p` at a usage limit, since a probe would have to reach a limit. The patterns are the best knowledge when it was built (see the ticket). If a limit isn't recognized, the run behaves as before (failed tries, then a stop for help) and the run's log has the real text, so the patterns can be fixed then. Waiting for the reset and going on without the user is a later backlog item, "The runner waits out Claude's usage limit".

### The App's token

The runner needs a token for every GitHub call and push. It makes a new one before each phase of a run ("One run", step 3). Each lasts an hour. `scripts/agent-token.sh` makes one:
1. **A JWT,** made with `openssl` from the App's private key, `${XDG_CONFIG_HOME:-$HOME/.config}/jd-cookie-agent/app.pem`: header `{"alg":"RS256","typ":"JWT"}`, payload `{"iat": <now - 60>, "exp": <now + 540>, "iss": "<client id>"}`, each part base64url-encoded, signed with `openssl dgst -sha256 -sign`. The client ID is in `${XDG_CONFIG_HOME:-$HOME/.config}/jd-cookie-agent/app.env`, as `APP_CLIENT_ID=…`. It isn't secret.
2. **The installation:** `GET /repos/<owner>/<repo>/installation`, with the JWT, gives the installation's `id`.
3. **The token:** `POST /app/installations/<id>/access_tokens` with the JWT, and the body `{"repositories": ["<repo>"]}`, so the token reaches only this repo, even if the App is ever installed on more. Both calls use `curl`, which reads the headers, with the JWT, from its stdin (`-H @-`) and writes the answer to its stdout, so the JWT and the token are never on a command line, where `ps` shows them, or in a file.

The token is handled as an opaque string: GitHub's installation tokens start `ghs_`, are a few hundred characters long, and contain dots (since GitHub's stateless tokens rolled out, 2026-10-02; the App's was 390 characters with two dots on 2026-11-23). Nothing checks its length or shape. It reaches `gh` as `GH_TOKEN`, and `git` through a credential helper that reads it from the environment, with `origin` set to `https://github.com/<owner>/<repo>.git`. The helper is set only in the runner's own environment, with git's configuration variables, so every `git` command the runner runs has it, `scripts/ticket.sh`'s claim push included, and the clone's `.git/config` never does: `GIT_CONFIG_COUNT=2`, `GIT_CONFIG_KEY_0=credential.helper` with an empty value (which drops any helper from the user's config), and `GIT_CONFIG_KEY_1=credential.helper` with a small shell function that answers only `get` requests for the host `github.com`, with `username=x-access-token` and `password=$GH_TOKEN`. It's never written to a file, a log, or a URL. If any step fails, the run logs which one, with the HTTP status, and exits 1.

Commits in the clone, the claim commit included, have the App's bot as author and committer: `jd-cookie-agent[bot]` and `358547770+jd-cookie-agent[bot]@users.noreply.github.com`, with the id read from `GET /users/jd-cookie-agent[bot]` at run time, not hard-coded. GitHub then shows the commits as the App's.

The App's permissions, on this repository only, as the user set them up for all three parts:
- **Contents:** read and write, to push branches.
- **Pull requests:** read and write, to open PRs (and, in part 2, reply to review comments).
- **Issues:** read and write, for labels and PR comments.
- **Actions:** read, for the failed jobs' logs (part 2).
- **Checks** and **Commit statuses:** read, for `gh pr checks` (part 2).
- **Metadata:** read (always on).
- Not **Workflows**: a push that changes `.github/workflows/` is refused by GitHub. The runner then stops for help with the reason "This ticket changes a workflow, which the runner's App can't push." The reasons are in the ticket.

### Checking the setup

`scripts/agent-run.sh check` checks that `claude`, `gh`, `node`, `npm`, `curl`, `openssl`, `flock`, `bwrap`, `git`, and `timeout` are on `PATH`, that `bwrap` can hide a file (it makes a file in a temporary folder and checks it can't be read inside), that `bwrap` has no network (`/proc/net/dev` inside lists only `lo`; not `/sys/class/net`, which still shows the host's interfaces inside, and not a TCP listener, which can't be opened when the runner's own tests run inside the sandbox; probed 2026-11-19, also in a nested `bwrap`), that `app.pem` exists and only the user can read it (mode `600`), that `app.env` sets `APP_CLIENT_ID`, and that a token can be made (the steps of "The App's token"). It prints each result, and exits 1 if any fails. It writes nothing outside a temporary folder, and changes nothing on GitHub. A run does the same checks first, and stops if one fails. Part 3's `agent-timer.sh check` runs it too.

### Logs

Each run writes a log to `${XDG_STATE_HOME:-$HOME/.local/state}/jd-cookie-agent/logs/<UTC time>.log`: each step it took, the commands it ran with their exit codes, and the agent's output. It keeps the last 200 logs. The script also prints the log as it goes.

## Security and configuration

- **Who can trigger it:** only the user running the script (and, in part 3, the user's timer). Its input is `main` (only the user merges) and the runner's own branches and PRs.
- **Credentials:** the App's private key, on the user's machine only, readable only by the user, never in the repo. Each run's token lasts an hour and reaches only this repo, with the permissions above. The agent never has it. The user's own `gh` login and deploy key aren't used. The agent's Claude login is the user's.
- **Pushing to `main`:** the App's contents permission would let it push to `main`, and `main` has no ruleset today (`gh api repos/<owner>/<repo>/rules/branches/main` returns `[]`). The runner never pushes to `main`: it pushes only branches it claimed. See "Setup" for the ruleset.
- **Untrusted text:** this part passes no PR comments to the agent. Its input is the ticket's design doc on `main`.
- **Failure modes:**
  - GitHub can't be reached: the run logs the failed command and exits 1. The next run tries again.
  - The agent fails or times out: that counts as a failed try.
  - Claude's usage limit: the run stops for help at once, with the reset time (see "Claude's usage limit").
  - Two runs at once: the lock.
  - A crash mid-build: the next run finds a claim with no PR and stops for help.
- **The project's rules:**
  - Rule 1 (count before you check): the 3 tries are counted in the run before each try, and only one run works at a time (the lock), so no two runs count at once.
  - Rule 2 (no shared state in process memory): the runner keeps no state between runs. One runner per machine, and one ticket at a time, are out of scope for more.
  - Rule 3: `docs/devops.md` gets the runner's section in the same PR.
  - Rule 4: the runner's agent follows `next-ticket`, which leaves versions to release-please.
  - Rule 5: the new `scripts` CI job follows it. The runner itself runs outside GitHub Actions.
- **No new settings.** The limits and the labels are constants at the top of `agent-run.sh`. For the tests only, `AGENT_RUN_ORIGIN` replaces the clone's `origin` URL (by default `https://github.com/<owner>/<repo>.git`), `AGENT_RUN_GITHUB_API` the API's base URL, `AGENT_RUN_MACHINE_ID_FILE` the path of `/etc/machine-id`, and `AGENT_RUN_AGENT_TIME`, `AGENT_RUN_CHECK_TIME`, `AGENT_RUN_TITLE_TIME`, and `AGENT_RUN_KILL_AFTER` the time limits. The tests set `GIT_ALLOW_PROTOCOL=file`, so no git command in them can reach GitHub.
- **Known gaps:**
  - The agent can run `npm` scripts, which can run any code in the repo, like the hooks and tests already do.
  - The time limit doesn't cap cost. `--max-budget-usd` only applies to API keys, and this uses the user's login. A build uses up part of the user's usage limits, which their own sessions share.
  - **The agent can read the machine's credentials:** it runs as the user, so an allowed command such as `node -e` can read `app.pem`, the user's `gh` token (`~/.config/gh/hosts.yml`), and the deploy key (`~/.ssh/github_test01`, which can push to Test01), despite Claude's rules. It could then send them anywhere: an allowed `node` or `npm` command can reach any host. Only the checks and the title check, in the sandbox, have no network. What limits the damage: the App and the `gh` token reach only this repo, the ruleset keeps everyone off `main` except by a merged PR, and the user can revoke the App key or the deploy key on GitHub. Closing the gap is two backlog items (the user's decision, 2026-11-19): "Run the runner's agent as its own Linux user", then "A credential broker for the runner".
  - Anyone else with the user's account on this machine can read `app.pem` too, and act as the App on this repo. Revoking the key on the App's page stops that.

## Setup

Done once per machine, by the user:
1. **The App** `JD-cookie-Agent` (GitHub → Settings → Developer settings → GitHub Apps), as for release-please's App in `docs/devops.md`: no webhook, installable only on this account, with the permissions in "The App's token", installed on Test01 only.
2. **Its key and client ID:** a private key saved as `~/.config/jd-cookie-agent/app.pem` with mode `600`, in a folder with mode `700`, and `APP_CLIENT_ID=<client id>` in `~/.config/jd-cookie-agent/app.env`. `scripts/agent-run.sh check` checks both, and makes a token.
3. **Qodo:** "Allow GitHub bot reviews" on, with release-please's App on the list of logins that aren't reviewed: `test01-release-please[bot]` (its login in GitHub's API), and `app/test01-release-please` (as `gh` shows it), since it's not known which form Qodo matches.
4. **A ruleset for `main`** (Settings → Rules → Rulesets): require a pull request, and block force pushes and deletion, with no bypass. Then nobody, the App included, pushes to `main` except by merging a PR. `gh api repos/<owner>/<repo>/rules/branches/main` lists `pull_request`, `non_fast_forward`, and `deletion`.

## Implementation map

- `scripts/agent-run.sh`: one run, as in "Processing", and `check`. The credential helper is in it, as git configuration variables ("The App's token"), not a file of its own.
- `scripts/agent-run/build.md`, `fix-checks.md`: the agent's prompts.
- `scripts/agent-run/settings.json`: the agent's Claude permissions ("The agent"), with placeholders for the secret folders.
- `scripts/agent-token.sh`: makes the App's token ("The App's token"), and prints it only to a file descriptor the runner reads.
- `scripts/test/agent-run.test.sh`: the tests below, run by `npm run test:scripts` at the root. They need `jq`, `git`, `openssl`, and the root `node_modules` (for the real commitlint).
- `package.json` (root): the script `test:scripts`, which `check` runs after the server's and the app's checks.
- `.github/workflows/ci.yml`: the job `scripts`, on `ubuntu-24.04`, following rule 5 like the other two: checkout, `setup-node` with Node 24 and the npm cache, `npm ci` at the root (the tests run the real commitlint, a root dev dependency, as `pr-title.yml` installs it), then `npm run test:scripts`.
- `.husky/pre-commit`: `scripts` is a third part beside `server` and `app`. When `scripts/` has staged changes, it needs the root `node_modules` (or says to run `npm install` at the root, as it does for the others), links it into the snapshot, and runs `npm run test:scripts` there, on the staged content.
- `.gitignore`: `.agent/`, and `*.pem`, so no App key in a working tree is committed.
- `docs/features/0007-agent-runner.md`: this doc, with a row in the Features table of `docs/README.md`.
- `docs/devops.md`: "The runner", a short section on operating it, linking this doc for the rest.
- `AGENTS.md`: a line in the table for the runner.

## Acceptance checks

Checks 1 to 6 are in `scripts/test/agent-run.test.sh`. It runs the runner against a scratch setup: a local bare repo as `origin`, holding a copy of the backlog with one `ready` ticket; stub `gh`, `claude`, `curl`, `npm`, and `bwrap` commands first on `PATH` (the `curl` stub answers the two token calls with a fake token of 520 characters, `ghs_` and two dots, as GitHub's are), which record how they were called and answer from fixture files, with lists long enough to need a second page; and an `npm` stub, in which `npm ci` links the repo's root `node_modules` into the clone (so the title check runs the real commitlint, with no network) and does nothing in `server/` and `app/`, and `npm run check` passes, fails, or hangs on cue. `AGENT_RUN_ORIGIN` points the clone at the bare repo. Each check passes when the script prints `ok N`, and CI runs it. The cases that need a real `bwrap` or a real TCP listener print `skip N` instead when `AGENT_RUN_IN_SANDBOX=1`. The other cases still run there: they use the `bwrap` stub, whose setup probe answers as a working sandbox would, and no runner code opens a listener. The reason for the skips: the runner's own checks run the root `check`, and so these tests, inside the sandbox, where a listener can't be opened (probed 2026-11-19: `EACCES`). They run in CI and in `npm run check` on the user's machine.

1. **No ticket:** with no `ready` ticket, a run claims nothing, calls `claude` 0 times, and logs `no ready ticket`.
2. **Build:** with one `ready` ticket, a run creates its claim branch on the bare `origin`, calls `claude` once with the build prompt, runs the check stub once, pushes the branch, and opens a PR (not a draft) with the title from `.agent/pr.md`, the rest of it as the body, and the label `agent-run` only. The labels are listed with `--paginate`: with 120 labels, one already on the second page isn't created again. The claim commit and the agent's commit have the App's bot as author and committer. The labels are created first when the `gh` stub says they don't exist.
3. **Check retries:** with the check stub failing every time, the run calls `claude` 3 times in all, then opens a draft PR with `needs-help`. The run folder has `base.txt`, `commits.bundle`, and `uncommitted.patch`: with the agent stub making one commit and leaving one new untracked file and one changed binary file, restoring them in a fresh clone of the bare `origin`, as "Stopping for help" says, gives the clone's tree exactly: both when the stop pushed the commit, and when the push was refused. With the agent stub making a merge commit, the restored history has the merge. With the agent stub writing `stop.md` and changing nothing, the folder has only `base.txt`, and restoring it gives the base. With an agent stub that ignores SIGTERM, its try ends at the kill time (shortened by the test). With a check stub that changes a tracked file and passes, the try fails. With a 70,000-character `stop.md`, output, and `pr.md` body, the draft's description is under 60,000 characters and starts with the reason and the run folder. With the check stub hanging, the try fails after the time limit (shortened by the test), and the next try runs. With it failing once, then passing, it opens a normal PR after 2 tries. With a `pr.md` title that commitlint rejects, the title counts as a failed check, and `gh pr create` is never called with it; with a good title, the real commitlint passes it (no stub). With the agent stub replacing `commitlint.config.mjs` in the clone by one that accepts every title and writes a file when loaded, a title only `main`'s config rejects still fails, and the file isn't written. With a commitlint stub that hangs, the title check fails after its time limit (shortened by the test). With the agent stub leaving an uncommitted change, the try fails before `npm run check` runs, and the fix prompt gets `git status`'s list.
   - **Stops before a PR:** with the agent stub writing `.agent/stop.md`, the run opens a draft PR with `needs-help` and `stop.md` in its description, in one PR call, and posts no comment. With the `gh`/push stub refusing a push that changes `.github/workflows/`, it opens the draft PR from the branch as it is on `origin`, and the description names the saved files.
   - **Usage limit:** with the agent stub printing `Claude AI usage limit reached` and a reset time as its last line and exiting 1, in try 1, the run calls `claude` once, never runs the check stub, and opens a draft PR with `needs-help` whose description starts with the limit reason and that line. The same in try 2 (after a failed check) stops after 2 `claude` calls. With the stub printing the same line but exiting 0, or exiting 1 with no matching line, the try counts as an ordinary failed try.
   - **Bad agent output:** with `.agent/pr.md` left over from an earlier try and the agent stub writing nothing, the try fails. With the build try writing `pr.md`, the checks failing once, and the fix try writing `pr.md` again, the PR gets the fix try's title, and the fix prompt held the build try's `pr.md`. With a good title but no `Ticket:` line in the body, or one inside another line, or with another path, the try fails, and the fix prompt says so. A valid `Ticket:` line with a body of 58,000 characters (115,000 bytes, more than a pipe holds) passes. A body over 60,000 characters fails the try, and the fix prompt says so: GitHub refuses one over 65,536 (the tests' `gh` stub does too).
4. **Crash, lock, and open PRs:**
   - a claim branch with no PR gets a draft PR with `needs-help`, and no `claude` call
   - a claim branch whose PR was merged, and one whose PR was closed, get no PR and no `claude` call, and the run goes on to `ticket.sh list`
   - a claim branch with another agent's name in its `Claimed-By` trailer is never touched. The agent name is `runner-` and the first 12 characters of the machine id (a stub `/etc/machine-id` path in the test)
   - a second run while the first holds the lock exits 0 at once
   - a claim branch with an open PR, with `needs-help` or without, gets no `claude` call, no comment, and no new claim, and the run logs `PR #<n> is open`
   - an open PR with no labels (its labels call failed) gets `agent-run` back, and `needs-help` too when its description is a stop's, with no `claude` call
   - a claim with no PR, whose branch on `origin` moved on while the clone stayed behind with an uncommitted change: the saved work restores the clone's tree
   - a claim with no PR, whose local branch shares no commit with `origin`: `base.txt` says `none`, and the saved work restores the clone's tree
   - a claim that exits 5 (the ticket withdrawn) before any agent run, with a `pr.md` from an earlier ticket in the clone: the draft gets the fallback title and none of the old `pr.md`, and its reason is the claim's message
5. **The token:** with a test key made by `openssl genrsa` and the `curl` stub:
   - the JWT the stub receives verifies with the key's public half (`openssl dgst -sha256 -verify`), its `iss` is the client ID, and `exp - iat` is 600
   - the fake 520-character token reaches the `gh` stub as `GH_TOKEN`
   - the credential helper, asked by `git credential fill` for `https://github.com` in the runner's environment, answers `username=x-access-token` and the token, and nothing for another host; a credential helper in the user's own git config is never asked or told (git's empty `credential.helper` resets the list); and the clone's `.git/config` has no `credential.helper`. (A push to a local bare `origin` never asks a credential helper. Probed 2026-11-19, so the helper is tested on its own.)
   - a new token is made after the agent's last run, before the PR is opened (every phase makes a new token, so no clock stub is needed)
   - `curl` never writes an answer to a file (no `-o`), and the `curl` stub records its whole command line before it parses it
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
   - with a check that adds a push URL and an `insteadOf` rewrite to `.git/config`: the push still reaches `origin`, and the sandbox mounts the clone's `.git` read-only
   - with a hook left in the clone's `.husky/_` (ignored there by husky's own `.gitignore`) by an earlier ticket, the next claim's push doesn't run it
   - with the agent stub overwriting the filled settings file it was given, the next try's settings are filled again
   - with the agent stub adding an `insteadOf` rewrite and a push URL to a decoy repo, and an fsmonitor command, to the clone's `.git/config`: the push reaches `origin`, the decoy gets nothing, the fsmonitor command never runs, and the config is put back
7. **The real setup:** on the user's machine, after setup steps 1 and 2, `scripts/agent-run.sh check` passes every check, including making a token, and nothing changes on GitHub.
8. `npm run check` passes locally and in CI.
9. **A real run by hand:** with a small ticket `ready` first in the backlog, `scripts/agent-run.sh` on `main` claims it, builds it with the real `claude`, gets the checks green, and opens a PR as `jd-cookie-agent[bot]`, or stops with a draft PR and `needs-help`. The run's log and the PR show it, and Qodo reviews the PR.

## Changes

- 0007: A runner that builds a ready ticket into a PR ([ticket](../tickets/0007-agent-runner.md))
