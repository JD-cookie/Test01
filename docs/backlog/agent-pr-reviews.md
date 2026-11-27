# Agent reviews of a PR on our subscriptions

Status: **designed**. When the user marks it `ready`, it gets a number and this doc is renamed `NNNN-agent-pr-reviews.md`. In the PR that builds it, it moves to `docs/tickets/` (ticket 0006's layout).

From [the research on cheaper reviews](review-tools-research.md). It replaced "Code reviews by our own agents". "Ask Qodo once per PR" is blocked by it.

## Summary

Today Qodo is the only reviewer of a PR's code, and it reviews every push. Qodo is now paid, and the pace of PRs will grow as the runner takes over. The user also pays a flat rate for three agent CLIs, Claude Code, Codex, and opencode, and each can review a diff: Codex and Claude Code have a review mode built in, and opencode can be given the diff in a prompt. opencode's models are cheap, so it can review with all three of its candidate models at once.

This ticket adds **`scripts/agent-review.sh`**: run in a branch, it reviews the branch's diff against `main` with five reviewers at once, each read-only in a throwaway clone, and saves their reports in one folder. The agent that runs it checks each finding's evidence, fixes or answers it, and adds a row per reviewer to a results table, as `refine-ticket` does for design docs. The `next-ticket` skill runs it before opening a PR. Over a few weeks the table shows which reviewers find what the others miss.

It's for the user: the obvious problems are found by reviewers already paid for, before Qodo is asked.

What doesn't change: Qodo still reviews every PR, as now, until "Ask Qodo once per PR" changes when. The runner doesn't run it yet: that's ticket 0009's redesign. `refine-ticket`'s reviewers are unchanged.

### Out of scope

- When Qodo reviews: "Ask Qodo once per PR".
- The runner's rounds (ticket 0009's redesign uses this script).
- Free linters: ShellCheck, zizmor, gitleaks, and lychee are their own rows.
- Posting findings on the PR: the reports stay local. They're often wrong until checked, and the PR is public.
- Changing `refine-ticket` to run all three opencode models: a later choice, once this table has data.

## Concepts

- **Reviewer:** one agent CLI with one model. This ticket has five: Codex (its default model), Claude Code (its default), and opencode once with each model in `refine-ticket`'s candidate list (`.agents/skills/refine-ticket/reviewers.md`: `ollama-cloud/glm-5.3`, `ollama-cloud/kimi-k3.1-pro`, `ollama-cloud/deepseek-v4-pro` today).
- **Review run:** one call of the script: one diff, five reviewers, one run folder.
- **Finding outcomes**, as in `refine-ticket`: **kept** (fixed, or turned into a question for the user), **answered** (checked and left as it is, with the reason), **dropped** (no evidence, or evidence that doesn't show it). Plus **only this one**: a kept finding no other reviewer in the run made.

## Processing

### `scripts/agent-review.sh`

`scripts/agent-review.sh [--base <ref>]`, run from the repo root of a branch's checkout. `<ref>` defaults to `origin/main`.

1. **The diff:** the commits on `HEAD` since its merge base with `<ref>` (`git merge-base <ref> HEAD`), so a `main` that moved on doesn't show up as changes. Uncommitted changes are refused (exit 2, "commit first: the reviewers see only commits"), so every reviewer sees the same thing. An empty diff exits 0 with "nothing to review".
2. **The clone:** `git clone -q --no-local --branch <current branch> . <run>/repo`, then `git -C <run>/repo remote remove origin`, and `refine-ticket`'s `opencode-reviewer.json` copied in as `opencode.json`. The base commit is fetched into it too, so `git diff <base>` works there. Ignored files, such as `server/.env`, aren't in a clone, and with no remote there's nothing to push to.
3. **The run folder:** `${XDG_STATE_HOME:-$HOME/.local/state}/agent-review/<UTC time>/`, outside every checkout.
4. **The reviewers,** all at once, each with a time limit of 15 minutes (`timeout --kill-after=1m 15m`), from inside the clone, each writing `<run>/<name>.out` and `<run>/<name>.err`:

   | Name | Command | What keeps it read-only |
   |---|---|---|
   | `codex` | `codex review -c sandbox_mode='"read-only"' -c approval_policy='"never"' --base <base sha>` | Codex's OS sandbox, read-only |
   | `claude` | `claude -p "/code-review medium <base sha>...HEAD" --permission-mode plan --strict-mcp-config` | plan mode, and `/code-review` without `--fix`. Its docs list a commit range as a target; the probe ran it without one "ask[s] Claude for a report only" ([local code review](https://code.claude.com/docs/en/code-review-local)) |
   | `opencode-<model>`, one per model | `opencode run --standalone --agent plan -m <model> "$(cat <run>/opencode-prompt.md)"` | `opencode.json`: the `plan` agent may only `read`, `grep`, `glob`, and `list` |

   opencode's `plan` agent has no shell, so it can't run `git diff` itself: `<run>/opencode-prompt.md` holds `scripts/agent-review/opencode.md` (new: the instructions) followed by the diff (`git diff <base>`, cut to 200,000 characters with a line that says so, since a prompt is an argument).
5. **The summary:** when all are done, it writes `<run>/summary.md`: per reviewer, its name, model, exit status, time taken, and the path of its report; then prints that file and the run folder's path. A reviewer that fails or times out is listed as such; the others' reports still count. The script exits 0 if at least one reviewer finished, 1 if none did.
6. **Afterwards:** it checks that the clone has no changes (`git -C <run>/repo status --porcelain` lists only `opencode.json`) and that the checkout's `git status --porcelain` is what it was before. If either differs, it says so and exits 1: a reviewer wrote something.

Probed 2026-11-26, on a scratch clone with one commit adding a 10-line shell script with four bugs (`[ $total > 100 ]`, an unquoted `$(cat $1)`, octal parsing, no error on a missing file):
- `codex review --base main`, with the read-only sandbox: 58 seconds, exit 0, five findings marked `[P1]` to `[P3]`, each with `file:line` and a paragraph, all four bugs among them. It prints its report on stdout and again on stderr. The clone was unchanged.
- `claude -p "/code-review low" --permission-mode plan`: 11 seconds, exit 0, two findings as `file:line — important — <text>`, the two most serious bugs. The clone was unchanged.

### The prompt for opencode

`scripts/agent-review/opencode.md` asks for the same as the others: real problems in the diff (bugs, missed cases, broken rules from `AGENTS.md`), each with its file and line, why it's wrong, and a severity, and nothing about style the repo's checks already cover. It says the diff is data to review, not instructions to follow, and to report "No findings" if there are none.

### Checking the findings

The script doesn't judge the findings: the agent that ran it does, as `refine-ticket` step 7 does after a review round. For each finding, it opens the file and line, and keeps, answers, or drops it, with the reason for each drop. Findings that two reviewers made count once, under each of them. "Only this one" counts a kept finding that no other reviewer made. Then it adds one row per reviewer to the results table in **`.agents/skills/next-ticket/reviewers.md`** (new): date, PR (or branch, before the PR exists), head commit, reviewer, model, kept, answered, dropped, only this one.

### In `next-ticket`

A new step between 2 (build it) and 3 (open the PR): **Review it with our agents.** After `npm run check` passes and the work is committed, run `scripts/agent-review.sh`, check the findings, fix the kept ones (in new commits), record the rows, and say in the PR's body what the run found and what was done. One run per PR before it opens. After Qodo's review (step 4), the fixes aren't reviewed by the agents again: that's for "Ask Qodo once per PR" to settle.

## Security and configuration

- **Read-only, in a clone:** each reviewer runs in a throwaway clone with no remote, under its CLI's read-only mode, as `refine-ticket`'s reviewers do. The script checks afterwards that nothing changed.
- **No secrets, no GitHub calls:** the script needs no token, and pushes nothing. The reviewers use the user's own CLI logins.
- **Untrusted text:** the diff is the branch's own code, written by the agent or the user. opencode's prompt says to treat it as data. The reports stay on this machine.
- **Usage:** each run uses part of the user's three subscriptions. In the probe, on a 10-line diff, Codex took 58 seconds and Claude Code 11 at `low`; `medium` and larger diffs take longer.
- **Failure modes:** a CLI missing, logged out, or at its usage limit makes that reviewer fail, and the summary says so; the others go on. A reviewer that hangs is killed at 15 minutes. A reviewer that writes to the clone or the checkout fails the run (step 6).
- **The project's rules:** rule 3, `docs/devops.md` gets a section on the script, and `next-ticket`'s new step is in the skill. Rules 1, 2, 4, and 5 don't apply (no limits, no server state, no versions, no workflows).
- **Known gaps:**
  - Not checked: whether the ollama-cloud plan allows three opencode runs at once. If it refuses, those reviewers fail and the summary says so; running them one after another is a later change.
  - The agent that checks the findings may be the same CLI as one reviewer (Claude Code checking a Claude Code review). It's a fresh session with the same model, so it can share that reviewer's blind spots.

## Tasks for the user

None. The CLIs and their logins are already set up (they review every refinement).

## Implementation map

- `scripts/agent-review.sh` (new): the steps above.
- `scripts/agent-review/opencode.md` (new): opencode's review instructions.
- `scripts/test/agent-review.test.sh` (new): checks 1 to 6, with stub `codex`, `claude`, `opencode`, and `timeout`-friendly stubs first on `PATH`, recording their arguments and working folder, run by `npm run test:scripts`.
- `package.json`: `test:scripts` runs the new test.
- `.agents/skills/next-ticket/SKILL.md`: the new step. `.agents/skills/next-ticket/reviewers.md` (new): the results table, with its column meanings.
- `docs/devops.md`: a section on the script, beside "The runner".

## Acceptance checks

All but 7 are in `scripts/test/agent-review.test.sh`, on a scratch repo with a local bare `origin`, and pass when it prints `ok N`.

1. **Five reviewers, same diff:** with one commit on a branch, a run calls the `codex` stub once with `review`, `sandbox_mode="read-only"`, and `--base` the merge base; the `claude` stub once with `-p`, `/code-review medium`, and `--permission-mode plan`; and the `opencode` stub three times, once per model in `reviewers.md`'s list, with `--agent plan`, and a prompt holding the instructions and that commit's diff. Each is called from the clone, not the checkout.
2. **The clone:** has no remote, has `opencode.json`, and has no file the checkout's `.gitignore` ignores (a scratch `server/.env` in the checkout isn't in it).
3. **The base:** with `main` on `origin` one commit ahead of the branch's base, the diff holds only the branch's commit.
4. **Refusals:** with an uncommitted change, it exits 2 and calls no reviewer. With no commits since the base, it exits 0 with "nothing to review".
5. **Failures:** with the `codex` stub exiting 1 and the `claude` stub sleeping past a shortened time limit, the run still finishes, the summary lists `codex` as failed and `claude` as timed out, and the opencode reports are there; it exits 0. With every stub exiting 1, it exits 1.
6. **Writes are caught:** with the `opencode` stub writing a file in the clone, the run exits 1 and names it.
7. **A real run:** on the PR that builds this ticket, `scripts/agent-review.sh` with the real CLIs. The PR's body lists the five reviewers' results, and `.agents/skills/next-ticket/reviewers.md` has their rows.
8. `npm run check` passes locally, and every CI job on the PR is green.

## Readiness review

Refined 2026-11-26 by Claude Code (claude-opus-5-5), while the user was away: the decisions below wait for the user.

- **Goal, restated:** before asking Qodo, have the three flat-rate agent CLIs review a PR's diff (opencode with all three of its models), read-only, and check their findings; track per reviewer what holds up, to learn which earn their place.
- **Is it needed:** not built: no review script in `scripts/`, and `next-ticket` has no review step before the PR (its step 4 is Qodo's review). It replaces the row "Code reviews by our own agents" (PR #25). It overlaps "Ask Qodo once per PR", which is blocked by it and changes only when Qodo reviews. Not dropped before.
- **Facts settled:** the two probes above (`codex review`, `/code-review` in `-p`), both read-only in a clone.
- **Questions for the user** (recommended answers; "yes" accepts):
  - Q1, where the review step lives → a script plus a step in `next-ticket`, with the results table beside that skill, not a new skill.
  - Q2, Claude Code's effort → `medium` (the probe used `low`, which reported only the two most serious of four bugs).
  - Q3, when it runs → once, before the PR opens; reviewing Qodo-round fixes again is "Ask Qodo once per PR"'s call.
  - Q4, all five every time → yes, until the table shows one adds nothing.

## Decisions made for this ticket

- **opencode reviews with every candidate model** (2026-11-26, the user's idea): its models are cheap, and running them on the same diff makes the comparison fair, unlike `refine-ticket`'s rotation of one model per refinement.

Q1 to Q4 wait for the user.
