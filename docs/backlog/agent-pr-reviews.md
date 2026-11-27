# Agent reviews of a PR on our subscriptions

Status: **designed**. When the user marks it `ready`, it gets a number and this doc is renamed `NNNN-agent-pr-reviews.md`. In the PR that builds it, it moves to `docs/tickets/` (ticket 0006's layout), and that PR adds its spec doc, `docs/features/NNNN-agent-pr-reviews.md`.

From [the research on cheaper reviews](review-tools-research.md). It replaced "Code reviews by our own agents". "Ask Qodo once per PR" is blocked by it.

## Summary

Today Qodo is the only reviewer of a PR's code, and it reviews every push. Qodo is now paid, and the pace of PRs will grow as the runner takes over. The user also pays a flat rate for three agent CLIs, Claude Code, Codex, and opencode, and each can review a diff: Codex and Claude Code have a review mode built in, and opencode can be given the diff as a file. opencode's models are cheap, so it reviews with all three of its candidate models at once.

This ticket adds **`scripts/agent-review.sh`**: run in a branch, it reviews the branch's commits since `main` with five reviewers at once, each read-only in one throwaway clone, and saves their reports in a run folder. The agent that runs it checks each finding's evidence, fixes or answers it, and adds a row per reviewer to a results table, as `refine-ticket` does for design docs. The `next-ticket` skill runs it once before opening a PR. Over a few weeks the table shows which reviewers find what the others miss.

It's for the user: the obvious problems are found by reviewers already paid for, before Qodo is asked.

What doesn't change: Qodo still reviews every PR, as now, until "Ask Qodo once per PR" changes when. The runner doesn't run it yet: that's ticket 0009's redesign. `refine-ticket`'s reviewers are unchanged.

### Out of scope

- When Qodo reviews: "Ask Qodo once per PR".
- The runner's rounds (ticket 0009's redesign uses this script).
- Free linters: ShellCheck, zizmor, gitleaks, and lychee are their own rows.
- Posting findings on the PR: the reports stay local. They're often wrong until checked, and the PR is public.
- Changing `refine-ticket` to run all three opencode models: a later choice, once this table has data.
- Reviewing again after Qodo's rounds: "Ask Qodo once per PR" settles that.

## Concepts

- **Reviewer:** one agent CLI with one model, with a file-safe name. This ticket has five: `codex` (its configured default model), `claude` (its default), and `opencode-<model>` once per model in `refine-ticket`'s candidate list (`.agents/skills/refine-ticket/reviewers.md`), named without the provider: `opencode-glm-5.3`, `opencode-kimi-k3.1-pro`, `opencode-deepseek-v4-pro` today.
- **Review run:** one call of the script: one base and head, five reviewers, one run folder.
- **Finding outcomes**, as in `refine-ticket`: **kept** (fixed, or turned into a question for the user), **answered** (checked and left as it is, with the reason), **dropped** (no evidence, or evidence that doesn't show it). Plus **only this one**: a kept finding no other reviewer in the run made.

## Processing

### `scripts/agent-review.sh`

`scripts/agent-review.sh [--base <ref>]`, run from the repo root of a branch's checkout. `<ref>` defaults to `origin/main`.

1. **Pin what's reviewed.** It reads, once, at the start: `head=$(git rev-parse HEAD)`, `ref=$(git rev-parse <ref>^{commit})`, `main=$(git rev-parse origin/main^{commit})`, and then `base=$(git merge-base $ref $head)`, from those shas only. It uses only these from then on, so a commit or a fetch while it runs doesn't change what's reviewed. If any of them fails (a `--base` that doesn't resolve, no `origin/main`, or no merge base), it prints which and exits 7, and no reviewer runs. Exit 7 covers every setup step that fails before a reviewer starts: the run folder can't be made, the clone or its checkout of `<head>` fails, or the policy can't be read from `$main`. The run folder is removed then, if it was made. One exception: if the clone can't check out `<head>` because the branch was reset or amended after the pin (the commit is no longer in the checkout's refs), that's the checkout moving, exit 6. The merge base, not `<ref>` itself, so a `main` that moved on doesn't show up as changes.
   - **Uncommitted changes** are refused: if `git status --porcelain` lists anything, untracked files included (ignored ones aren't listed), it prints `agent-review: commit first: the reviewers see only commits` and exits 2, and no reviewer runs.
   - **Nothing to review:** if `base` equals `head`, it prints `agent-review: nothing to review` and exits 3.
2. **The run folder:** `${XDG_STATE_HOME:-$HOME/.local/state}/agent-review/<UTC time>-<pid>/`, made with `mkdir` (not `mkdir -p` for the last part), so two runs at once can't share one, as the runner names its run folders (`scripts/agent-run.sh`).
3. **The clone:** `git clone -q --no-local --no-checkout . <run>/repo`, then `git -C <run>/repo checkout -q --detach <head>`, and `git -C <run>/repo remote remove origin`. It checks that the clone's `HEAD` is `<head>`. Ignored files, such as `server/.env`, aren't in a clone, and with no remote there's nothing to push to.
4. **opencode's permissions come from `main`, not the branch:** it removes `<run>/repo/opencode.json` (so a symlink the branch put there is replaced, not written through, as the runner writes its files), then runs `git show $main:.agents/skills/refine-ticket/opencode-reviewer.json` **in the checkout**, where `$main` was pinned (the clone may not have that commit, if `origin/main` is ahead of the branch), and writes its output there: always `origin/main`'s pinned commit, whatever `--base` says, since the branch under review could change that file. Then, as `refine-ticket` does, it checks the policy opencode will really use, which also catches any other config the branch adds: `opencode debug agents --standalone` from the clone, with a time limit of 2 minutes, must show the `plan` agent's rules starting with `* * deny` and allowing only `read`, `grep`, `glob`, and `list`.
   - The rules are anything else: it exits 5 before any reviewer runs.
   - `opencode` is missing, or the check fails or times out: the three opencode reviewers are `failed` ("opencode's policy couldn't be checked") and aren't started; Codex and Claude Code run as usual.
5. **The diff for opencode:** `git -C <run>/repo diff <base> <head> > <run>/diff.patch`, outside the clone. opencode's `plan` agent has no shell, so it gets the diff as an attached file (`opencode run -f`). Not as part of the prompt: one command-line argument is limited to 128 KiB on Linux, and a 200,000-character argument fails with "Argument list too long" (probed below).
6. **Before:** it records `git --no-optional-locks status --porcelain --ignored` of both the clone and the checkout, and then touches `<run>/started`. Every `git status` the script runs has `--no-optional-locks`, so its own status calls don't rewrite `.git/index` and look like a reviewer's write.
7. **The reviewers,** all at once, from inside the clone, each with a time limit (`timeout --kill-after=1m "$AGENT_REVIEW_TIME"`, 15 minutes by default; `AGENT_REVIEW_TIME` is for the tests), each writing `<run>/<name>.out` and `<run>/<name>.err`:

   | Name | Command | What keeps it read-only |
   |---|---|---|
   | `codex` | `codex review -c sandbox_mode='"read-only"' -c approval_policy='"never"' --base <base>` | Codex's OS sandbox, read-only, and no approvals to leave it |
   | `claude` | `claude -p "/code-review medium <base>...<head>" --permission-mode plan --strict-mcp-config` | Claude Code's plan mode, no MCP servers, and `/code-review` without `--fix`, which "ask[s] Claude for a report only" ([local code review](https://code.claude.com/docs/en/code-review-local)) |
   | `opencode-<model>` | `opencode run --standalone --agent plan -m <provider/model> -f <run>/diff.patch "$(cat scripts/agent-review/opencode.md)"` | `opencode.json` from `main`: the `plan` agent may only `read`, `grep`, `glob`, and `list` |

   Claude Code keeps its shell: with `--tools Read,Grep,Glob`, as `refine-ticket` runs it on design docs, it couldn't run `git diff`, and said it reviewed a guess (probed below). Its plan mode is Claude Code's own rule, not the OS's, so step 9 checks for writes.
8. **The summary:** when all are done, `<run>/summary.md` lists per reviewer: its name, its model (`codex`: the `model:` line its header prints on stderr; `opencode-*`: the model passed; `claude`: `default`), its status (`finished`, `failed (exit N)`, or `timed out`), the time taken, and its report's path; then the base and head shas. The script prints it and the run folder's path.
9. **After:**
   - **The clone:** any file in `<run>/repo`, its `.git` included, that's newer than `<run>/started` (`find <run>/repo -newer <run>/started -type f`, `.git/index` aside, since a reviewer's own `git status` may refresh it; a staged change still shows in the status compared next) is a write: an edited ignored file or `.git/config` too, not only a new one. So is any change in the clone's status, which also shows a deleted file, and any difference between the clone's `opencode.json` and the policy written in step 4 (`cmp`): opencode loads it when it starts, and a reviewer that edited it would have changed what a later process read. It prints them, and exits 4: a reviewer wrote something.
   - **The checkout:** if its `git status --porcelain --ignored` differs, it prints the difference and exits 4 too. If its `HEAD` isn't the pinned `<head>` anymore (a commit while the run went on, at any step, by the user or the calling agent), that's not a write: the summary says `the checkout moved during the run: the review is of <head>, and HEAD is now <new>`, and it exits 6.
10. **Cleanup:** it deletes `<run>/repo`, keeping the reports, the diff, and the summary.

**Exit status:** 0 if at least one reviewer finished and nothing was written; 1 if none finished; 2 uncommitted changes; 3 nothing to review; 4 a reviewer wrote something; 5 opencode's permissions aren't read-only; 6 the checkout's head moved during the run; 7 the setup failed before any reviewer started. Exit 4 wins over 6, and both over 0 and 1.

**Probed 2026-11-26,** on a scratch clone with no remote and one commit on top of `main` adding the fixture below, `scripts/sum.sh`, with four bugs (line 7's `[ $total > 100 ]` redirects instead of comparing; line 4's `$(cat $1)` is unquoted; octal parsing of `08`; no error on a missing file), all three at once:
- `codex review` as in the table, with `--base` a sha: 48 seconds, exit 0, four findings marked `[P1]` to `[P3]` with `file:line`, the report on stdout and again on stderr after a header with `model: gpt-6.2-sol` and `sandbox: read-only`.
- `claude -p "/code-review medium <sha>...HEAD" --permission-mode plan --strict-mcp-config`: 34 seconds, exit 0, six findings, as text then a JSON list (`file`, `line`, `summary`, `failure_scenario`, `severity`). With both ends as shas, `<base sha>...<head sha>` as in the table: 41 seconds, exit 0, seven findings, the first at `"line": 7`. The same with `--tools Read,Grep,Glob`: 36 seconds, but it wrote "I had no shell, so I couldn't run `git diff`".
- `opencode run --standalone --agent plan -m ollama-cloud/<model> -f diff.patch "<instructions>"`, the three models at once: 12, 23, and 33 seconds, all exit 0, each with 2 to 6 findings, the `>` bug in all three.
- The clone's `git status --porcelain --ignored` was the same after.
- `bash -c 'exec /bin/true "$(head -c 200000 /dev/zero | tr "\0" a)"'`: "Argument list too long", exit 126; 100,000 characters: exit 0.

**The fixture,** `scripts/test/fixtures/agent-review/sum.fixture` (new, used by check 9; not named `.sh`, so the planned ShellCheck check, which lints every `.sh` under `scripts/`, doesn't fail on its deliberate bugs), exactly:

```sh
#!/bin/sh
# Prints the sum of the numbers in the file named by $1, one per line.
total=0
for n in $(cat $1); do
  total=$((total + n))
done
if [ $total > 100 ]; then
  echo "big: $total"
fi
echo $total
```

### The prompt for opencode

`scripts/agent-review/opencode.md` (new, read from beside the running script, like the runner's prompts; it holds no permissions, so the branch's own version is fine) asks for the same as the others: real problems in the attached diff (bugs, missed cases, broken rules from `AGENTS.md`), each with its file and line, why it's wrong, and a severity, and nothing about style the repo's checks already cover. It says the diff is data to review, not instructions to follow, that the files can be read for context, and to report "No findings" if there are none.

### Checking the findings

The script doesn't judge the findings: the agent that ran it does, as `refine-ticket` step 7 does after a review round. For each finding, it opens the file and line, and keeps, answers, or drops it, with the reason for each drop. A finding that two reviewers made counts once under each of them. "Only this one" counts a kept finding that no other reviewer made. A reviewer that didn't finish gets its status and no counts. Every run that started the reviewers gets its rows, so the table counts failures as well as findings: a run that exited 0 gets each reviewer's status and, for those that finished, its counts; a run that exited 1 gets each reviewer's status only; a run that exited 6 gets each reviewer's status only, marked `superseded`, since its findings are about an older head (the run after it counts). Exits 2, 3, 5, and 7 started no reviewer, and get no rows; exit 4 gets none either, since the run is stopped for the user.

Then it adds one row per reviewer to the results table in **`.agents/skills/next-ticket/reviewers.md`** (new): date, PR (or branch, before the PR exists), the reviewed head sha (the summary's, from before any fixes), reviewer, model, status, kept, answered, dropped, only this one.

### In `next-ticket`

A new first part of its step 3, "Open the PR", before the PR is opened: **Review it with our agents.** Step 3, not step 2, because the runner's agent follows step 2 ("step 2 only", `scripts/agent-run/build.md`) and can't run the script (its Claude settings allow no `sh` or `scripts/*` command), while the runner does step 3 itself. So the runner skips the review until ticket 0009 adds it. Adding a part to step 3 leaves the step numbers the runner and its spec cite ("`next-ticket` step 3") right. After `npm run check` passes and the work is committed, run `scripts/agent-review.sh`:
- **Exit 0:** check the findings, fix the kept ones in new commits (and run `npm run check` again), and say in the PR's body what the run found and what was done, naming any reviewer that didn't finish.
- **Exit 1** (no reviewer finished): run it once more. If it fails again, open the PR anyway, and say so in its body: the reviewers are a help, not a gate.
- **Exit 2:** commit, then run it again. **Exit 3:** nothing to review; go on.
- **Exit 4, 5, or 7:** stop and tell the user, with the script's output: a reviewer wrote something, opencode wasn't read-only, or the setup failed.
- **Exit 6:** the reviewed head is older than the branch now. Run it again, once the branch is still, so the PR's head is the one reviewed.

One run per PR, before it opens. The rows go into the table once, after the last attempt, from the summaries the agent kept: one commit, before the PR opens. Writing them between attempts would leave an uncommitted change, which the next attempt refuses (exit 2).

## Security and configuration

- **Read-only, in a clone:** each reviewer runs in a throwaway clone with no remote, under its CLI's read-only mode, and the script checks both repos afterwards (step 9). opencode's permissions come from `main`, so the branch under review can't loosen them.
- **What a reviewer can still reach:** each runs as the user, so, as `refine-ticket`'s reviewers can (`docs/features/0003-refine-ticket-skill.md`, "Known gaps"), it can read files outside the clone, such as the home folder, and its own CLI's login. Codex's sandbox limits writes, not reads. The script passes no token: it unsets `GH_TOKEN` and `GITHUB_TOKEN` in the reviewers' environment, and makes no GitHub call.
- **Untrusted text:** the diff is the branch's own code, by whoever wrote the branch: the calling agent, the user, or another agent. opencode's prompt says to treat it as data. The reports stay on this machine.
- **Usage:** each run uses part of the user's three subscriptions: in the probe, under a minute each on a 10-line diff, more on a large one.
- **Failure modes:** a CLI missing, logged out, or at its usage limit makes that reviewer `failed`, and the others go on. A reviewer that hangs is killed at the time limit. A write fails the run (exit 4). Two runs at once get their own folders.
- **The project's rules:** rule 3, a new spec doc and its Features row, and `docs/devops.md` (below). Rules 1, 2, 4, and 5 don't apply (no limits, no server state, no versions, no workflows).
- **Known gaps:**
  - Claude Code's plan mode is a rule of Claude Code, not of the OS: a reviewer that broke it could write outside both repos, where step 9 doesn't look.
  - The agent that checks the findings may be the same CLI as one reviewer (Claude Code checking a Claude Code review): a fresh session of the same model, so it can share that reviewer's blind spots.
  - The ollama-cloud plan's limits weren't checked beyond three short runs at once.
  - The reviewers read the branch's own instruction files from the clone: Codex and opencode `AGENTS.md`, Claude Code `CLAUDE.md` (which is `@AGENTS.md`). A branch that changes them can steer its own reviewers. Only opencode's permissions are pinned to `main`.
  - A branch that changes `opencode.json`: the reviewers see `main`'s copy in the clone, while the diff shows the branch's.
  - In the checkout, an edit to a file that was already ignored, such as `server/.env`, leaves its `git status` the same, so it isn't seen. The reviewers run in the clone, not the checkout, so this would take one that left the clone on purpose.

## Tasks for the user

None. The CLIs and their logins are already set up (they review every refinement).

## Implementation map

- `scripts/agent-review.sh` (new): the steps above.
- `scripts/agent-review/opencode.md` (new): opencode's review instructions.
- `scripts/test/fixtures/agent-review/sum.fixture` (new): check 9's fixture.
- `scripts/test/agent-review.test.sh` (new): checks 1 to 8, with stub `codex`, `claude`, and `opencode` first on `PATH`, each recording its arguments, its working folder, and its environment, and answering from fixture files; run by `npm run test:scripts`.
- `package.json`: `test:scripts` runs the new test.
- `.agents/skills/next-ticket/SKILL.md`: the new step. `.agents/skills/next-ticket/reviewers.md` (new): the results table, with its columns explained.
- `docs/features/NNNN-agent-pr-reviews.md` (new spec doc), with a row in the Features table of `docs/README.md` and a line in that file's Changes, as for the ticket system and the runner.
- `docs/devops.md`: a short section on running the script, beside "The runner", linking the spec doc, with a Changes line.

## Acceptance checks

Checks 1 to 8 are in `scripts/test/agent-review.test.sh`, on a scratch repo with a local bare `origin`, and pass when it prints `ok N`. Check 9 is a real run, and check 10 is `npm run check` and CI.

1. **Five reviewers, same pinned diff:** with one commit on a branch, a run calls the `codex` stub once with `review`, `sandbox_mode="read-only"`, `approval_policy="never"`, and `--base` the merge base's sha; the `claude` stub once with `-p`, `/code-review medium <base>...<head>`, `--permission-mode plan`, and `--strict-mcp-config`; and the `opencode` stub three times, once per model in `reviewers.md`'s list, each with `--agent plan`, `-m` the model, and `-f` a file holding exactly `git diff <base> <head>`. Each is called from the clone, with the clone's `HEAD` at the pinned head, and with no `GH_TOKEN` or `GITHUB_TOKEN` in its environment. With a commit made on the branch while the stubs run, the summary still names the first head, and says the checkout moved, and the run exits 6; the same with the commit made while the `opencode debug agents` stub runs, before any reviewer. With `origin/main` ahead of the branch at the start, the clone's `opencode.json` is `origin/main`'s. With `--base nosuchref`, it exits 7 and calls no reviewer; the same with `XDG_STATE_HOME` pointing at a file, so the run folder can't be made. With the branch reset to its parent between the pin and the clone (a stub `git clone` wrapper doing it), it exits 6. With `origin/main` moved after the start, the base and `opencode.json` are still the first ones.
2. **The clone:** has no remote, and no file the checkout's `.gitignore` ignores (a scratch `server/.env` in the checkout isn't in it). With the branch's `opencode-reviewer.json` changed to allow `bash`, the clone's `opencode.json` is still `main`'s. With a `main` whose copy allows `bash` (the `opencode debug agents` stub showing it), the run exits 5 and calls no reviewer.
3. **The base:** with `main` on `origin` one commit ahead of the branch's base, the diff holds only the branch's commit.
4. **A clean run isn't a write:** with the branch tracking an `opencode.json` identical to `main`'s policy (so step 4 replaces it with the same bytes), and stubs that only read, it exits 0.
5. **Refusals:** with a changed tracked file, and again with only an untracked file, it exits 2 and calls no reviewer; with only an ignored file, it runs. With no commits since the base, it exits 3.
6. **Failures:** with `AGENT_REVIEW_TIME=2s`, the `codex` stub exiting 1, and the `claude` stub sleeping 10 seconds, the run finishes, the summary lists `codex` as `failed (exit 1)` and `claude` as `timed out`, and the three opencode reports are there; it exits 0. With every stub exiting 1, it exits 1.
7. **Writes are caught:** with the `opencode` stub writing a new ignored file in the clone, the run exits 4 and names it. The same with the `codex` stub making a commit in the clone, with it appending to the clone's `.git/config`, with a stub editing a file the clone already had as ignored, with a stub deleting a tracked file in the clone, with a stub editing the clone's `opencode.json`, and with the `claude` stub writing a new file in the checkout. With the branch tracking an `opencode.json` that's a symlink to a file outside the clone, that file is unchanged, and the clone's `opencode.json` is `main`'s. With no `opencode` on `PATH`, the three opencode reviewers are `failed` and Codex and Claude Code still run.
8. **Two runs at once** get two run folders; the clone is gone after each run, and the reports, `diff.patch`, and `summary.md` are kept.
9. **A real run,** on the PR that builds this ticket, besides the branch's own run of the new `next-ticket` step: in a scratch clone of `main` with one commit adding the fixture as `scripts/sum.sh`, the ticket's script is run from there (`sh <the ticket's checkout>/scripts/agent-review.sh`, so its prompt comes from beside it, and `main`'s `opencode-reviewer.json` from the fixture clone). It exits 0, the summary lists all five as `finished`, and each report names line 7 of `scripts/sum.sh` in its own form (`sum.sh:7` for Codex and opencode, `"line": 7` for Claude Code). The PR's body shows that summary, and the matching line from each report. The fixture run's findings aren't fixed or recorded in the table: they're about the fixture.
10. `npm run check` passes locally, and every CI job on the PR is green.

## Readiness review

Refined 2026-11-26 by Claude Code (claude-opus-5-5), while the user was away: the decisions below wait for the user.

- **Goal, restated:** before asking Qodo, have the three flat-rate agent CLIs review a PR's diff (opencode with all three of its models), read-only, and check their findings; track per reviewer what holds up, to learn which earn their place.
- **Is it needed:** not built: no review script in `scripts/`, and `next-ticket` has no review step before the PR (its "Take it through review" step is Qodo's). It replaces the row "Code reviews by our own agents" (PR #25). It overlaps "Ask Qodo once per PR", which is blocked by it and changes only when Qodo reviews. Not dropped before.
- **Facts settled:** the probes above.
- **Definition of Ready:** 1 pass. 2 pass. 3 pass. 4 pass (one script, its test, one skill step, two docs). 5 pass after round 1. 6 pass (none). 7 pass after round 1. 8 pass (rule 3). 9 pass after round 1. 10 fails until Q1 to Q5 are answered.
- **Questions for the user** (recommended answers; "yes" accepts):
  - Q1, where the review step lives → a script plus a step in `next-ticket`, with the results table beside that skill, not a new skill.
  - Q2, Claude Code's effort → `medium` (at `low` the first probe reported only the two most serious of four bugs; at `medium`, six findings).
  - Q3, when it runs → once, before the PR opens.
  - Q4, all five every time → yes, until the table shows one adds nothing.
  - Q5, if no reviewer finishes twice → open the PR anyway and say so: the reviewers help, but don't gate the PR.
- **Review round 1:** Codex (gpt-6.2-sol) and opencode (ollama-cloud/glm-5.3).
  - Restatements: both match.
  - Codex 1 and opencode 4 (blocking): Q1 to Q4 are open. Done: answered, they wait for the user.
  - Codex 2 and opencode 3 (blocking, needs a run): the prompt as one argument breaks Linux's limit. Done: probed (200,000 characters fails, 100,000 runs), and the diff goes as an attached file (`-f`), probed with three models.
  - Codex 3, opencode 2 and 5 (blocking, needs a run): the shipped commands weren't the probed ones. Done: probed the exact commands, a sha for `--base`, and the `<sha>...HEAD` range.
  - Codex 4 (blocking): Claude Code lacked `refine-ticket`'s tool limit, and check 1 didn't assert every flag. Done: probed `--tools Read,Grep,Glob` (it can't see the diff), so plan mode stays, with step 9's write check and a known gap; check 1 asserts every flag.
  - Codex 5 (blocking): the branch supplied opencode's permissions. Done: fixed, from `main`, verified before any reviewer runs (exit 5, check 2).
  - Codex 6 and opencode 15 (blocking, minor): the write check missed ignored files, commits, and refs. Done: fixed, status with `--ignored`, `HEAD`, and refs in both repos (check 6).
  - Codex 7 (blocking): the head could move between the merge base and the clone. Done: fixed, both shas pinned at the start (check 1).
  - Codex 8 and opencode 7 (blocking, minor): two runs could share a folder, and model ids have a slash. Done: fixed, `<time>-<pid>` with `mkdir`, and file-safe names (check 7).
  - Codex 9 (blocking): `next-ticket` had no rule for each outcome, and two outcomes shared exit 1. Done: fixed, six exit statuses and what the skill does on each, and Q5.
  - Codex 10 and opencode 10 (blocking, minor): the table couldn't tell a failed reviewer from a clean one, and the models of the default CLIs weren't defined. Done: fixed, a status column, the reviewed sha, and where each model comes from.
  - Codex 11 and opencode 13 (blocking, minor): the real-run check passed with five failures, and the test file's checks were misnumbered. Done: fixed, check 8 on a known fixture, and the checks' locations.
  - Codex 12 (blocking): "no secrets" didn't say what reviewers can read. Evidence: `docs/features/0003-refine-ticket-skill.md`'s known gap. Done: fixed, "What a reviewer can still reach", and tokens unset.
  - Codex 13 and opencode 1 (blocking): no spec doc or Features row. Done: fixed, as for 0003, 0007, and 0008.
  - opencode 6 (minor, needs a run): three opencode runs in one folder at once. Done: probed, fine.
  - opencode 8 (minor): the test's time limit had no override. Done: fixed, `AGENT_REVIEW_TIME`.
  - opencode 9 (minor): the "base is fetched" sentence made no sense with no remote. Done: fixed, removed (the base is an ancestor of the head, so it's in the clone).
  - opencode 11 (minor): untracked files weren't stated. Done: fixed, they count; ignored ones don't (check 4).
  - opencode 12 (minor): "step 4" would be renumbered. Done: fixed, the steps named.
  - opencode 14 (minor): the backlog row drifted. Done: fixed.
  - opencode 16 (minor): run folders kept whole clones. Done: fixed, the clone is deleted after the run.
  - Dropped: 0.
- **Review round 2:** Codex (gpt-6.2-sol) and opencode (ollama-cloud/glm-5.3), blocking findings only.
  - Restatements: both match.
  - Codex 1 (blocking): the policy came from `--base`, and was written through whatever path the branch had at `opencode.json`. Evidence: `scripts/agent-run.sh:130`. Done: fixed, always `origin/main`'s pinned commit, the file removed first, and the effective policy checked (check 6).
  - Codex 2 (blocking): a missing or hung `opencode` stopped every reviewer. Done: fixed, the check has a time limit, and only exit 5 is a verified unsafe policy (check 6).
  - Codex 3 (blocking): the base could come from a later state than the head. Done: fixed, every sha pinned first (check 1).
  - Codex 4 and opencode 1 (blocking): a commit during the run looked like a reviewer's write. Done: fixed, exit 6 for a moved checkout, and the skill runs again (check 1).
  - Codex 5 (blocking): edits to existing ignored files and `.git/config` weren't seen. Evidence: `scripts/agent-run.sh:116`. Done: fixed, any file in the clone newer than the run's start (check 6).
  - Codex 6 (blocking): retries and outages weren't recorded. Done: fixed, every attempt gets its rows.
  - Codex 7 and opencode 2 (blocking, needs a run): the fixture wasn't written down, and the sha-to-sha Claude command wasn't probed. Done: probed (41 seconds, exit 0, `"line": 7` first), and the fixture's exact text is in the doc (check 8).
  - opencode 3 (blocking): check 8's run versus the branch's own run. Done: fixed, both run, and the fixture's findings aren't recorded.
  - Dropped: 0.
- **Review round 3:** Codex (gpt-6.2-sol) and opencode (ollama-cloud/glm-5.3), blocking findings only.
  - Restatements: both match.
  - Codex 1 (blocking): a commit during setup slipped past the moved-checkout check. Done: fixed, the final `HEAD` is compared with the pinned head (check 1).
  - Codex 2 (blocking): replacing `opencode.json` changes what reviewers read in the clone. Done: answered, a known gap: the diff still shows the branch's version.
  - Codex 3 and opencode 2 (blocking): a deleted file in the clone, and an edited ignored file in the checkout, weren't seen. Done: fixed for the clone (its status is compared too, check 6); the checkout's case is a known gap.
  - Codex 4 (blocking): which runs get rows wasn't defined per exit. Done: fixed.
  - Codex 5 (blocking): a `--base` that doesn't resolve had no exit. Done: fixed, exit 7 (check 1).
  - Codex 6 (blocking): check 8's invocation and evidence. Done: fixed.
  - opencode 1 (blocking, needs a run): `git show $main:` in the clone fails when `origin/main` is ahead, since a clone doesn't copy remote branches. Done: fixed, it runs in the checkout (check 1); the probe it suggests isn't needed once it does.
  - opencode 3 (blocking): a new numbered step would break the runner's "`next-ticket` step 3" references (`scripts/agent-run.sh:412`, `scripts/agent-run/build.md:5,16`, `docs/features/0007-agent-runner.md:84,102`). Done: fixed, it's the last part of step 2.
  - opencode 4 (blocking): the reviewers read the branch's own `AGENTS.md` and `CLAUDE.md`. Done: answered, a known gap, and "written by the agent or the user" corrected.
  - Dropped: 0.
- **Review round 4:** Codex (gpt-6.2-sol) and opencode (ollama-cloud/glm-5.3), blocking findings only.
  - Codex 1 and opencode 1 (blocking): as part of `next-ticket` step 2, the review would reach the runner's agent, which follows step 2 and can't run the script (`scripts/agent-run/build.md:5`, `scripts/agent-run/settings.json`). Done: fixed, it's the first part of step 3, which the runner does itself.
  - Codex 2 (blocking): `opencode.json` was exempt from the write check. Done: fixed, it's compared with the policy written (check 7).
  - Codex 3 and opencode 2 (blocking, needs a run): the script's own `git status` can rewrite `.git/index` after the start marker. Done: fixed without the probe: `--no-optional-locks` on every status, the statuses recorded before the marker, and `.git/index` left out of the file check (check 4).
  - Codex 4 (blocking): other setup failures had no exit. Done: fixed, exit 7 covers them (check 1).
  - Codex 5 (blocking, needs a run): a branch reset between the pin and the clone loses the head. Done: fixed, that's exit 6 (check 1).
  - Codex 6 (blocking): rows written between attempts would block the retry. Done: fixed, written once after the last attempt.
  - Dropped: 0.

## Decisions made for this ticket

- **opencode reviews with every candidate model** (2026-11-26, the user's idea): its models are cheap, and running them on the same diff makes the comparison fair, unlike `refine-ticket`'s rotation of one model per refinement.

Q1 to Q5 wait for the user.
