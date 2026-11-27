# The runner fixes Qodo's findings on its PRs

Status: **designed**. When the user marks it `ready`, it gets a number and this doc is renamed `NNNN-agent-review-rounds.md`. In the PR that builds it, it moves to `docs/tickets/` (ticket 0006's layout), and that PR edits the runner's spec doc, `docs/features/0007-agent-runner.md`, in place.

This is part 2 of 3, split on 2026-11-19 from "An agent that builds ready tickets on a timer":
1. [A runner that builds a ready ticket into a PR](../features/0007-agent-runner.md): the runner, run by hand. **Blocks this one.**
2. **This one:** the review step.
3. [Start the runner on a timer](agent-timer.md): blocked by both.

Terms, the agent and its sandbox, the App's token, the checks, and "Stopping for help" are part 1's. This doc only adds to them.

## Summary

Part 1's runner opens a PR and then leaves it to the user. This part adds the **review step**: when a run finds its PR open, it waits for Qodo's review and CI on the head commit, then runs a **round**: the agent reads Qodo's findings, the owner's comments, and the failed CI jobs, fixes what it confirms, answers the rest, and the runner pushes and replies. It stops with `needs-help` after 4 rounds, or when it's stuck. When a round has nothing left to change and CI is green, it comments `Ready for review by the user.`

It's for the user, who wants Qodo's findings handled without doing each round by hand, as AGENTS.md asks: every finding is fixed or answered with the reason.

What doesn't change: part 1's build step, the review rules, and the user merges.

### Out of scope

- The timer (part 3). Until it's built, the user runs `scripts/agent-run.sh` by hand, about every 15 minutes while a PR is in review.
- Comments by anyone but Qodo and the repo owner.
- Approving or merging PRs.
- Reviews by our own agents: "Code reviews by our own agents" is its own backlog item.

## Concepts

- **Round:** one pass of the agent over the review results of one push: Qodo's findings, the owner's comments, and failed CI jobs. It ends with a push, or with "nothing left to fix". If someone else pushes to the branch while it runs, it's dropped (step 10).
- **Round id:** the GitHub id of the round's `Agent round N started` comment. N is for people, and starts again at 1 when `needs-help` is removed. The markers and replies name a round by its id, so two rounds with the same N are never mixed up.
- **The runner's marker:** every comment and reply the runner posts ends with a hidden `<!-- jd-cookie-agent ... -->` marker. It records which commit a round reviewed and pushed, and when it collected the comments (see "The runner's records").
- **Removing `needs-help`:** the user's way to let the runner go on with a PR. It resets the round count.

## User-facing behavior

1. While the runner's PR is open, each round adds two comments from the runner: `Agent round N started`, then `Agent round N` with what it did, and a reply to each inline comment it was given.
2. When it's done, it comments `Ready for review by the user.`
3. If it stops for help, the PR gets the label `needs-help` and a comment that says why. To let it go on, fix what's needed, then remove the label. Removing it resets the round count. If the PR is a draft, the next run marks it ready for review first.
4. Don't push to the branch while a round runs (between `Agent round N started` and `Agent round N`): the runner drops that round and runs a new one on your commit, and the dropped one counts toward the 4.
5. Merge, or close the PR, as for any PR.

## Processing

### Changes to part 1

- **"Find its work":** an open PR **without** `needs-help` goes to the review step (below). An open PR with `needs-help` still gets nothing: the run logs `PR #<n> is open` and exits, so no other ticket starts while it's open (part 1: one ticket at a time).
- **"Stopping for help"** with a PR open: the same steps 1 and 2, then, instead of opening a PR, a comment with what part 1 puts in the draft's description (the reason, the run folder's path, and the output), with the marker `stop=1`, then the label `needs-help`. Comment first: if the run dies between the two, the next run adds the label (review step, step 1).
- **A draft PR:** the runner opens a draft only with `needs-help`, so a draft without it is one the user has let go on. The review step marks it ready for review (`gh api graphql`, `markPullRequestReadyForReview`) before it waits for Qodo (step 1).

### Review step

For the open PR without `needs-help`.

**The runner's records.** Everything it posts ends with a hidden marker, `<!-- jd-cookie-agent ... -->`, holding the fields below. Every run reads them back from the PR's comments, by `jd-cookie-agent[bot]` only. Every list it reads from GitHub (comments, review comments, reviews, the timeline, checks) is read in full, with `gh api --paginate`.
- `Agent round N started`, posted before the agent runs: `round=N reviewed=<sha>`, where `reviewed` is the head commit Qodo reviewed. Its comment's id is the round id. It counts toward the limit, but it doesn't mark the head as done: only a finished round does.
- `Agent round N`, posted when the agent and the checks are done, **before** the push: `round=N id=<round id> reviewed=<sha> cutoff=<time> pushed=<sha>`. `cutoff` is when the runner collected the round's input (step 3). `pushed` is the commit the round will push, or the same head if there's nothing to push. The agent's replies to inline comments are in the marker, as JSON, and so is a title change, with the old title and the new one. Posting the report before the push means a crash can't lose it: the next run finds `pushed` missing on `origin` and finishes the push (step 1).
- A stop for help: `stop=1`.
- A reply to an inline comment: `round=<round id>`.
- `Ready for review by the user.`: `ready=<sha>`.

The **last finished round** is the newest `Agent round N` comment, without "started", whose `pushed` commit is on the PR's branch at `origin` (`pushed` is `origin/<branch>` or an ancestor of it). A report whose push was abandoned (step 1) isn't a finished round: its cutoff isn't used, so its comments are collected again.

Times are GitHub's, never the machine's clock: "now" is the `Date` header of a `gh api -i` call made at the start of step 2, and the cutoff is the same for step 3. For the tests only, `AGENT_RUN_NOW` replaces "now".

Steps:
0. **Get the clone onto the branch,** before any step can stop for help: as part 1's build step 1, but on the PR's branch. `git fetch`, `git clean -ffdx`, `git switch -f -C <branch> origin/<branch>`, and delete every other local branch. Deleting a branch keeps its commits in the clone, so step 1 can still push one. (`.git/config` was written at the run's start, as in part 1. `npm ci` comes in step 6, only when a round runs.)
1. **Finish what the last run started,** in this order:
   - **A draft:** if the PR is a draft, mark it ready for review.
   - **A stop without its label:** if the newest comment with `stop=1` has no `labeled` event for `needs-help` after it in the PR's timeline, add the label and exit.
   - **The push:** if the newest `Agent round N` comment's `pushed` isn't on `origin/<branch>`:
     - If `origin/<branch>` is still at its `reviewed` commit, and no `stop=1` comment came after it: if the clone has the commit (`git cat-file -e <sha>^{commit}`), push it. If not, stop for help: "Round N's commits were lost before the push."
     - Otherwise, the branch moved on (someone pushed), or the run stopped after the report (GitHub refused the push, or the commits were lost), and the user has since removed `needs-help`. Then the push is **abandoned**: if the clone has the commit, it's saved in a new run folder (`base.txt` and `commits.bundle`, as in "Stopping for help" step 1), and the log says so. The round isn't finished (above), so its comments go to the next round again. This way, a refused or lost push never comes back after the user has dealt with it.
   - **The title:** if the last finished round's marker has a title change, and the PR's title is still the old one, set the new one.
   - **Replies:** if the last finished round's marker has replies that aren't posted yet (no reply by the App on that comment with the marker `round=<its round id>`), post them.
   - An `Agent round N started` with no `Agent round N` after it is a round that died before its report, or was dropped (step 10). It counts toward the limit (step 5), and nothing else: its head still needs a round.
2. **Wait for the review.** Qodo is done with the head commit when its review comment, the issue comment by `qodo-code-review[bot]` whose body contains `<h3>Code Review by Qodo</h3>`, contains `<!-- https://github.com/<owner>/<repo>/commit/<head sha> -->` (the full 40-character sha), **and** that comment's `updated_at` is at least `QODO_QUIET` (10 minutes) ago. Qodo's comments start with a blank line or with the heading, so the runner matches the heading anywhere, never as a prefix. Its other comment, `<h3>PR Summary by Qodo</h3>`, names the same commit, and doesn't count. The quiet time is because Qodo reviews in two passes: on PR #22, 28 seconds after the push of da44031 it edited its review comment to name da44031 with only the earlier findings marked resolved, and 2.5 minutes later it edited it again with a new finding (GraphQL `userContentEdits` of comment 7154060156). Across #22's 9 pushes, every edit came within about 3 minutes of a push, and none without one.

   CI is done when the head commit's check runs (`gh api --paginate repos/<owner>/<repo>/commits/<head sha>/check-runs`, the `check_runs` list) number at least one, and every one that counts has `status` `completed`. For each check `name`, only the newest check run counts (the highest `id`): editing the title runs `pr-title.yml` again on the same commit (it runs on `edited`), and its new result replaces the old one. No check runs at all means CI hasn't started yet. The list is complete by the time Qodo is done: on #22's last head, all 4 check runs started within 9 seconds of the push (17:26:28 to 17:26:37), well inside the 10 quiet minutes. A check run failed if its `conclusion` is anything but `success`, `neutral`, or `skipped`. CI here is GitHub Actions only, so the commit status API isn't used: on #22's head it says `pending` with 0 statuses. Every call is `gh api`, as in part 1, not `gh pr checks`.
   - **Either isn't done:** exit, and check again next run.
   - **Still not done 60 minutes after the head commit arrived:** stop for help: "Qodo or CI hasn't finished reviewing <sha> after 60 minutes." GitHub doesn't record when a commit was pushed (GraphQL's `pushedDate` is null for #22's commits), so the clock starts at the newest of: the PR's `created_at`, the earliest `started_at` of the head's check runs (or, with none, the head commit's committer date), the newest `Agent round N` comment's `created_at`, and the newest `unlabeled` event for `needs-help` in the PR's timeline. A commit's committer date alone could be days old for a commit pushed just now, while CI starts within seconds of a push. So a commit the user pushes before removing `needs-help` gets its full 60 minutes too.
3. **Collect what's new since the last finished round's `cutoff`** (or since the PR opened), for the round prompt. The new cutoff is "now" from step 2, taken before anything is read, so a comment posted while the runner reads is after it: at worst it's seen twice, never missed. A comment or review comment counts as new if its `updated_at` is after the cutoff, so an edited one counts too. A review counts as new if its `submitted_at` is after it: reviews have no `updated_at` (all 8 on PR #20 have only `submitted_at`).
   - Qodo's whole review comment: some findings are only there.
   - Everything by `qodo-code-review[bot]` and by the repo owner (`gh api repos/<owner>/<repo> --jq .owner.login`): inline review comments, the PR's own comments, and the bodies of reviews (`pulls/<n>/reviews`), such as a "Request changes" with no inline comment.
   - For each failed check run, the last 200 lines of its job's log: `gh api repos/<owner>/<repo>/actions/jobs/<id>/logs`, where `<id>` is the check run's `id`, which for GitHub Actions is the job's id (all 16 check runs on #22's last 4 heads have a `details_url` ending in `/job/<their id>`).

   A review whose body is empty is left out: inline comments each come with a review of their own with an empty body, by Qodo and by the owner alike (all 8 reviews on PR #20). The owner's comments include those the owner's own sessions post with the owner's `gh` login: they're the owner's account.

   Comments from anyone else are left out: the repo is public, so anyone can comment, and the agent would read their text as instructions. The runner's own comments, by `jd-cookie-agent[bot]`, are left out too.
4. **Is a round needed?** A round runs if any of these holds:
   - no finished round has `reviewed` equal to the head commit
   - step 3 found a new comment or review
   - `needs-help` was removed after the last finished round
   - `origin/main` has commits the branch doesn't

   Otherwise the last finished round reviewed this head and pushed nothing. Finish what its run would have done after it, in case that run died first or the round only changed the title (step 10): if CI is green and no `Ready for review by the user.` names the head, post it; if CI is red, stop for help: "CI still fails, and round N changed nothing." Then exit. A red CI with nothing new doesn't start a round: the round that saw it already ran.

   So every head commit Qodo reviews gets one round, even when Qodo found nothing. The agent decides what's open, from the review comment and the other comments. It can't be read reliably from Qodo's comment alone: on PR #12, with no findings, it starts with counts (`🐞 Bugs (0)`, `📘 Rule violations (0)`, `📎 Requirement gaps (0)`). On PR #10, after every finding was fixed, it had no counts, only a "Resolved findings" list, each finding marked `✓ Resolved`.
5. **Count rounds.** Count the `Agent round N started` comments since the last time `needs-help` was removed from the PR (the PR's timeline, event `unlabeled`), or since the PR opened. That count includes rounds that died or were dropped. If 4 are done, stop for help: "Qodo still has findings after 4 rounds." A round is counted before it runs, as rule 1 asks.
6. **Catch up with `main`:** `git merge origin/main` in the clone, on the branch since step 0, as `next-ticket` step 4 says (no rebase, so no force-push). If the merge has a conflict, `git merge --abort`, and stop for help: "Merging main has a conflict." Then, as in part 1's build step 1, `npm ci` at the root and in `server/` and `app/` (the merge can change their packages), and write `.git/config` and `.git/info/exclude` again.
7. **Start the round:** post `Agent round N started`, with its marker. If that post fails, exit 1: no round runs unrecorded.
8. **Run the agent** with the round prompt and the collected text. If step 4 found only that `main` moved on, the agent still runs: the merge can break something, and the checks show it.
   - It writes `.agent/round.md`, with each finding, whether it's confirmed, and what it did: fixed (with the commit) or answered (with the reason).
   - It writes `.agent/replies.json`, with one reply for each inline comment collected in step 3: `[{"comment_id": 123, "body": "…"}]`.
   - It updates the ticket doc's "Delivery and review" section, as `next-ticket` step 4 asks, only in a round that commits a fix, and in that commit. A round that only answers changes no file: its answers are in its `Agent round N` comment. Otherwise every round would make a commit, and no round would end with nothing to push.
   - If the title should change, it writes `.agent/pr.md` with the new title as its first line. In a round only that line counts: the PR's body isn't changed, and part 1's `Ticket:` line isn't required.
   - If it wrote `.agent/stop.md`, stop for help, with `stop.md` as the reason.
   - If it hit Claude's usage limit (part 1's "Claude's usage limit"), stop for help at once with that reason, here and in step 9's tries. The round still counts toward the limit of 4: it was recorded in step 7.
9. **Checks** as in part 1's build step 4, 3 tries, with the title check if there's a `pr.md`. A failed try runs the agent again with the round fix prompt (see "The agent"): the check's output (the last 200 lines), the collected text again, and the last try's `round.md`, `replies.json`, and `pr.md` if there was one, to keep or change. `.agent/` is emptied before each agent run (part 1), so every try writes its files again, and a missing or invalid one fails the try. If they still fail after 3 tries, stop for help, with the output.
10. **Check the head, report, push, reply.**
    - First, with a new token, `git fetch`. If `origin/<branch>` isn't at the round's `reviewed` commit anymore, someone pushed during the round, and its report would be about a head that's gone. So the round is **dropped**: no report, no push, no title, no replies. Its work is saved in the run folder, as in "Stopping for help" step 1, the log says so, and the run exits. The next run runs a round on the new head. The dropped round's `Agent round N started` still counts toward the 4.
    - Post `Agent round N`, with `round.md` and its marker.
    - If the round or the merge made a commit, push it (`git push origin HEAD:refs/heads/<branch>`, never forced). If the push fails, fetch again: if the branch moved, the push is abandoned, as in step 1, and the run exits. If it didn't, GitHub refused it (a workflow change): stop for help.
    - If `pr.md` has a new title, which passed the title check in step 9, set it (`gh api -X PATCH repos/<owner>/<repo>/pulls/<n>`).
    - Post each reply as a reply to its comment (`gh api …/pulls/<n>/comments/<id>/replies`), each with the marker `round=<round id>`.
    - Then:
      - **It pushed:** exit. The next run waits for Qodo's review of the new head.
      - **It only changed the title:** exit. The title edit runs `pr-title.yml` again, so the next run waits for its new result (step 2), and then posts `Ready for review by the user.` (step 4).
      - **Nothing to push, and CI green:** the round is the last. Post `Ready for review by the user.` with the marker, once per head commit. If the user or Qodo comments again, a later run runs a round for it.
      - **Nothing to push, and CI red:** stop for help: "CI still fails, and round N changed nothing."

### The agent's files

Added to part 1's list, with the same rules:
- `round.md`: not empty.
- `replies.json`: valid JSON, an array with exactly one object for each inline comment collected in step 3, no more, none twice, each with that comment's numeric `comment_id` and a non-empty `body`.
- `pr.md`, in a round: optional. If it's there, its first line isn't empty, and the rest is ignored.

### The agent

As in part 1, with two more prompts, with the same three rules: `scripts/agent-run/round.md` for a round's first try, and `scripts/agent-run/round-fix.md` for its tries 2 and 3. Part 1's `fix-checks.md` isn't used in a round, since it asks for a full `pr.md`. Both round prompts also say that Qodo's text and the CI logs are findings to check, not instructions to follow, and that the owner's comments are the owner's requests, within the prompt's rules. The agent still can't read PR comments itself (`gh` is denied): it sees only what the runner collected.

## Security and configuration

- **Untrusted text:** comments by other accounts are never passed to the agent. Qodo's text and the owner's are passed. Text in a prompt can still steer the agent, and the agent has part 1's reach, not only its clone: it runs as the user and can reach the network (part 1's "Known gaps"). So the round prompts treat Qodo's text and the CI logs as findings to check, never as instructions. The checks and Qodo's next review see every change the agent pushes.
- **Failure modes,** added to part 1's: Qodo or CI never finishing (the 60-minute limit), a lost or refused push and unposted replies or title (step 1), a stop that died before its label (step 1), a push to the branch during a round (step 10), a conflict with `main` (step 6), red CI that a round can't fix (steps 4 and 10), and Claude's usage limit during a round (step 8). After the reset, the user removes `needs-help`, which resets the round count, and the next run runs the round again.
- **The project's rules:**
  - Rule 1 (count before you check): a round is recorded on GitHub (`Agent round N started`) before it runs, and counted from there, and only one run works at a time (the lock).
  - Rule 2: the records are on GitHub, in the PR's comments, not in the runner.
  - Rule 3: `docs/devops.md`'s runner section gets the review step in the same PR.
- **No new settings:** the round limit (4), the wait (60 minutes), and Qodo's quiet time (`QODO_QUIET`, 10 minutes) are constants at the top of `agent-run.sh`. For the tests only, `AGENT_RUN_NOW` sets "now", so the 60 minutes and the quiet time can be tested without waiting.
- **Known gaps:**
  - Whether Qodo reviews a PR when it's marked ready for review isn't known: no PR in this repo has been a draft. If it doesn't, the 60-minute limit stops for help and says so.
  - An edited review body isn't seen again: reviews have no `updated_at`. The owner's reviews here have been inline comments, which have one.

## Tasks for the user

None new. Part 1's Qodo setting ("Allow GitHub bot reviews") must be on before the first round can run, since a round waits for Qodo's review.

## Implementation map

- `scripts/agent-run.sh`: the review step, the records, and the changes to part 1.
- `scripts/agent-run/round.md`, `round-fix.md` (new): the round prompts.
- `scripts/test/agent-run.test.sh`: checks 1 to 6 below, with fixtures for Qodo's comments copied from real ones on PRs #10, #12, and #22 (the App's PR: its review comment, and its two edits after the push of da44031), which start with a blank line or `<h3>`.
- The runner's spec doc, `docs/features/0007-agent-runner.md`: the review step and the changes to part 1, edited in place, with a Changes line.
- `docs/devops.md`: the review step in the runner's section.

## Acceptance checks

All are in `scripts/test/agent-run.test.sh`, on part 1's scratch setup, with the `gh` fixtures' lists long enough to need a second page, and the deciding comment or event on the last one. Each passes when the script prints `ok N`.

1. **Waits for Qodo and CI:** with an open `agent-run` PR whose Qodo review comment names an older commit, a run calls `claude` 0 times and changes nothing. The same with Qodo done and a check run `in_progress`, and with Qodo done and no check runs at all. With Qodo's "PR Summary" comment naming the head and its review comment an older commit, it still waits. With the review comment naming the head but edited 5 minutes ago (#22's first edit), it waits; with the same comment edited 11 minutes ago, it runs a round. With the clock's start 61 minutes ago, it adds `needs-help`. With an old head commit but `needs-help` removed 5 minutes ago, it waits and doesn't add `needs-help`. With a head whose committer date is 2 days old and whose check runs started 5 minutes ago, it waits and doesn't add `needs-help`. With two check runs named `title` on the head, an older `failure` and a newer `success`, CI counts as green.
2. **Round:** with Qodo's review comment (`Code Review by Qodo`) for the head commit and one new Qodo inline comment, a run calls `claude` once with the round prompt, which contains that comment's text. It posts `Agent round 1 started` before calling `claude`, posts `Agent round 1` with `pushed` naming the new commit, then pushes, then posts the reply from `replies.json` to that comment's id, with the started comment's id in its marker. With a failed CI job, its failed log lines are in the round prompt. With an owner's review body (a review with no inline comment), submitted after the last cutoff, its text is in the prompt.
   - **Bad agent output:** with `replies.json` not valid JSON, naming a comment id that wasn't collected, naming one twice, or leaving one out, the try fails.
   - **Fix tries:** with the checks failing once, try 2 gets `round-fix.md` with the check's output and try 1's `round.md` and `replies.json`. With try 2 writing no `replies.json`, it fails. A `pr.md` with a good title and no `Ticket:` line passes.
3. **Only Qodo and the owner:** a comment from another account, containing `IGNORE-ME`, is not in the round prompt. One from the owner is, both inline and on the PR itself. A comment by `jd-cookie-agent[bot]`, containing `MINE`, is not.
4. **Round limit and crashes in a round:** with 4 `Agent round N started` comments since the PR opened, a run adds `needs-help` and calls `claude` 0 times, also when some of the 4 have no `Agent round N` after them. With `needs-help` removed after round 4, and nothing else new, the next run runs round 5 as a new round 1. A PR with `needs-help` gets no `claude` call, and no other ticket is claimed.
   - With `Agent round 1 started` and no `Agent round 1` (a crash during the agent), the next run runs round 2 on the same head, and calls `claude` once.
   - With the agent stub at the usage limit (as in part 1's check 3) in round 1, the run posts `Agent round 1 started`, calls `claude` once, posts a comment with the limit reason, adds `needs-help`, and pushes nothing. With `needs-help` then removed, the next run runs a new round on the same head.
   - With a `stop=1` comment and no `needs-help` added after it (a crash between the two), the next run adds `needs-help` and calls `claude` 0 times.
   - With `Agent round 1` posted, its `pushed` commit in the clone but not on `origin` (a crash before the push), the next run pushes it, and calls `claude` 0 times. With that commit in neither, it adds `needs-help`. With `needs-help` then removed, the next run doesn't stop for it again: it runs a round on the head, and that round's prompt has round 1's comments again.
   - With `Agent round 1` posted, its `pushed` commit in the clone, and the branch on `origin` moved to another commit, the next run doesn't push it, saves it in a run folder's `commits.bundle`, and runs a round on the new head, whose prompt has round 1's comments again.
   - With `Agent round 1` posted and pushed but its reply not, the next run posts the reply, and calls `claude` 0 times for it. With an older round 1, from before `needs-help` was removed, already replying to the same comment, the next run still posts the new round's reply.
   - With `Agent round 1` posted with a title change, pushed, and the PR's title still the old one, the next run sets the new title.
   - With `Agent round 1` posted, nothing to push, CI green, and no `Ready for review by the user.` (a crash before it), the next run posts it, and calls `claude` 0 times.
   - With the branch on `origin` moved while the agent stub runs, the run posts no `Agent round 1`, pushes nothing, posts no reply, and its run folder has the round's work. The next run runs round 2 on the new head.
   - With an owner comment dated after the round's `cutoff` but before its `Agent round 1` comment, the next run runs a round with it.
   - With an owner comment from before the cutoff, edited after it, and no new commit, the next run runs a round with it.
   - With a round on commit A that pushed commit B, and Qodo's comment edited to name B, the next run runs a round on B.
5. **Done:** with the review comment for the head commit, no round on that head yet, CI green, and the agent stub changing nothing, a run calls `claude` once, posts `Agent round N`, and comments `Ready for review by the user.`, in that same run. The clone has no change to a tracked file, and nothing is pushed. A second run calls `claude` 0 times and doesn't comment again.
   - **CI stays red:** with a failed CI job and the agent stub changing nothing, the run adds `needs-help` with "CI still fails, and round N changed nothing." and doesn't post `Ready for review by the user.`
   - **A title change in a round:** with the agent stub writing only a new, good title in `pr.md`, the run sets it, posts `Agent round N`, pushes nothing, and doesn't post `Ready for review by the user.` The next run, with the title check's new run green, posts it, and calls `claude` 0 times. With a title commitlint rejects, the try fails, and the title isn't set.
   - **Main moved on:** after `Ready for review by the user.`, with `main` on the bare `origin` one commit ahead of the PR's branch, the next run runs a round, and its push holds a merge of `main`.
   - **A draft PR after `needs-help`:** with `needs-help` removed from a draft PR, and Qodo's review comment naming an older commit, the run marks the PR ready for review, then waits, and calls `claude` 0 times.
   - **A conflict with main:** with a conflicting commit on `main`, the run adds `needs-help` and calls `claude` 0 times.
   - **A workflow change in a round:** with the push stub refusing the round's push, the run adds `needs-help`, and the run folder has `commits.bundle` with the round's merge of `main`. With `needs-help` then removed, the next run doesn't try that push again.
   - **`stop.md` in a round:** with the agent stub writing `.agent/stop.md`, the run adds `needs-help` with `stop.md` as the comment, and opens no new PR.
6. `npm run check` passes locally, CI's jobs pass on the PR, and `docs/devops.md`'s runner section has the review step.

The first real round is part 3's real run, on ticket 0004. Part 1's real run by hand (its check 9) comes before, but the user takes that PR through review.

## Readiness review

Split on 2026-11-19 from "An agent that builds ready tickets on a timer", after its review round 2. That doc's two review rounds covered this part's design too; their record is in [the runner's ticket](../tickets/0007-agent-runner.md#readiness-review). Answered questions from then that apply here (see part 1's record): Q1 (the App, so the runner's comments are told apart by author), Q2 (a round on every commit Qodo reviews), Q4 (a workflow change stops with `needs-help`), Q6 and Q7 (the agent's limits).

Refined on its own 2026-11-25 by Claude Code (claude-opus-5-5), after part 1 (ticket 0007) and ticket 0008 were built.

- **Goal, restated:** today the runner opens its PR and leaves the review to the user, who fixes or answers each of Qodo's findings by hand. This part makes each run take its open PR one step through review instead: wait for Qodo and CI on the head, then one round where the agent fixes or answers Qodo's findings, the owner's comments, and failed CI, and the runner pushes and replies; up to 4 rounds, then `needs-help`, and `Ready for review by the user.` when nothing is left. The user still merges.
- **Is it needed:** not built: `scripts/agent-run.sh` has no review code, and an open PR only logs `PR #<n> is open` (looked in the script, `docs/features/`, and `docs/tickets/`). No overlap: the only open PR was #23 (STATUS.md, merged 2026-11-26), and "Code reviews by our own agents" is a separate row. Not dropped before (the backlog's history).
- **Facts settled while refining** (each written into its section):
  - Qodo reviews in two passes, so the head commit in its comment doesn't mean it's done (PR #22's edit history).
  - Qodo edits its comments only after a push, never after a comment alone (PR #22: every edit within about 3 minutes of one of its 9 pushes).
  - Qodo posts inline comments on some PRs (#10: 4, #20: 5, #22: none), each with a review whose body is empty. Reviews have `submitted_at` and no `updated_at`.
  - CI is check runs only; the commit status API says `pending` with 0 statuses. A check run's id is its Actions job's id (16 of 16 on #22's last 4 heads), and `gh api …/actions/jobs/<id>/logs` returns the log. All 4 check runs start within seconds of a push. The doc's `gh pr checks` and `gh run view` became `gh api`, as part 1 requires.
  - GitHub doesn't record push times (`pushedDate` is null), so the 60-minute clock starts at the newest of four times, and a commit the user pushes before removing `needs-help` isn't timed out at once.
  - Qodo's bot reviews are on: it reviewed the App's PR #22 (part 1's setup task 3). No PR in the repo has been a draft, so its handling of drafts isn't known (a known gap).
- **Definition of Ready:** 1 pass (the summary says the problem, for whom, and what doesn't change). 2 pass (above). 3 pass (an out-of-scope list: the timer, other commenters, merging, our own agents' reviews). 4 pass (one area, the runner: `agent-run.sh`, two prompts, its tests, and two docs; one behavior, the review step; part 1, of a similar size, was built in one session). 5 pass after the facts above and review round 1: every message, marker, and call is named, and every crash point has a recovery. 6 pass (none new; Qodo's bot reviews, confirmed on). 7 pass (checks 1 to 6, each in `agent-run.test.sh` with its expected result, failure paths included). 8 pass (rules 1, 2, and 3 addressed). 9 pass (untrusted text, failure modes, known gaps). 10 pass after Q1 to Q5.
- **Questions and answers:**
  - Q1, when Qodo counts as done → its review comment names the head and hasn't been edited for 10 minutes (2026-11-25).
  - Q2, a task for the user to keep Qodo reviewing after its trial ends → no: it's a task for the user in `STATUS.md` (PR #23), not this ticket's.
  - Q3, when the ticket doc's "Delivery and review" is updated → only in a round that commits a fix, in that commit (2026-11-26).
  - Q4, a draft PR after `needs-help` is removed → marked ready for review before the wait for Qodo (2026-11-26).
  - Q5, a push to the branch during a round → the round is dropped, and the next run runs one on the new head (2026-11-26).
- **Review round 1:** Codex (gpt-6.2-sol) and opencode (ollama-cloud/glm-5.3).
  - Codex's restatement: the owner wants the runner to handle Qodo's findings, the owner's feedback, and CI failures on its PRs, one round per run, recording enough to resume, and saying when the PR is ready or needs help; the owner still merges. opencode's: the same, naming the files it touches and what's out of scope. Both match.
  - Finding (Codex 11, opencode 1 and 2; blocking): a round's tries 2 and 3 had no prompt, part 1's fix prompt and file rules demand a full `pr.md` with a `Ticket:` line, and `.agent/` is emptied before each try. Evidence: `0007-agent-runner.md:80,101-102`. Done: fixed, `round-fix.md`, each try writes its files again, and `pr.md` is optional in a round, first line only (steps 8 and 9, "The agent's files", "The agent", check 2).
  - Finding (Codex 2, opencode 4 and 7; blocking): a refused or lost push stays in the report, so after the user removes `needs-help` the next run tries it again, or stops again. Evidence: steps 1 and 10. Done: fixed, the push is abandoned once a stop came after the report or the branch moved, and an abandoned round isn't finished, so its comments are collected again (step 1, check 4, check 5).
  - Finding (Codex 3, opencode 8; blocking and minor): round numbers restart after `needs-help` is removed, so `round=N` on a reply can name two rounds. Evidence: step 5 and step 1's reply check. Done: fixed, the round id (Concepts, the records, check 2, check 4).
  - Finding (opencode 5 and 12, Codex 1; blocking, minor, blocking): a crash between the stop comment and its label wasn't recovered as the doc claimed, the stop comment's marker had no fields, and a crash after the report could lose the title change and the `Ready` comment. Evidence: "Changes to part 1", step 10. Done: fixed, `stop=1`, step 1 adds a missing label and finishes the title, and step 4 finishes `Ready` or the red-CI stop (check 4).
  - Finding (Codex 4; blocking): one finished check run could look like all of CI. Evidence: step 2. Done: answered, with the evidence in step 2: on #22 all 4 check runs started within 9 seconds of the push, inside Qodo's 10 quiet minutes.
  - Finding (Codex 5; blocking): a title-only round could stop for help on the old title's check result. Evidence: steps 2 and 10, `pr-title.yml` runs on `edited`. Done: fixed, only the newest check run per name counts, and a title-only round exits and lets the next run post `Ready` (steps 2, 4, 10, checks 1 and 5).
  - Finding (Codex 6, opencode 9; blocking, minor): a comment posted while the runner reads could fall before the recorded cutoff, and the machine's clock was compared with GitHub's. Evidence: step 3. Done: fixed, the cutoff and "now" are GitHub's `Date` header, taken before reading.
  - Finding (Codex 7, opencode 15; blocking, minor): reviews have no `updated_at`. Evidence: `gh api repos/JD-cookie/Test01/pulls/20/reviews` (only `submitted_at`). Done: fixed, reviews count by `submitted_at`, and an edited review body is a known gap.
  - Finding (Codex 8, opencode 17; blocking, minor): a draft waited for Qodo before it was marked ready, and Qodo may not review drafts. Evidence: no PR in the repo was ever a draft. Done: asked the user (Q4), fixed, and a known gap.
  - Finding (Codex 9, opencode 10 and 11; blocking, minor, minor): the review step could stop before the clone was on the PR's branch, never cleaned the clone, and never ran `npm ci` after merging `main`. Evidence: step 6 and part 1's build step 1. Done: fixed, step 0 and step 6.
  - Finding (Codex 10; blocking): a push during a round left a report about a head that's gone. Evidence: step 10. Done: asked the user (Q5), fixed, step 10 and check 4.
  - Finding (Codex 12; blocking): the head commit's committer date can be days old for a commit pushed now, so the 60 minutes could run out at once. Evidence: step 2. Done: fixed, the earliest check run's `started_at` (check 1).
  - Finding (Codex 13; blocking): "the agent can only change files in its clone" was false: only the checks are sandboxed. Evidence: `0007-agent-runner.md:180-184`. Done: fixed, "Untrusted text" points to part 1's known gaps, and the round prompts treat Qodo's text and logs as findings, not instructions.
  - Finding (opencode 3; blocking): updating "Delivery and review" in every round makes every round commit, so no round ends with nothing to push. Evidence: step 8. Done: asked the user (Q3), fixed.
  - Finding (opencode 6; minor): whether an open `needs-help` PR stops the run or lets another ticket start. Evidence: "Changes to part 1". Done: fixed, the run exits (check 4).
  - Finding (opencode 13; minor): no check covered a title change in a round. Done: fixed, check 5.
  - Finding (opencode 14; minor): Q2 said the Qodo task was in `STATUS.md`, which was true only once PR #23 merged. Done: fixed, Q2 names PR #23 (merged 2026-11-26).
  - Finding (opencode 16; minor): the job id rested on one check run. Evidence: `gh api …/commits/<sha>/check-runs` for #22's last 4 heads. Done: answered, 16 of 16, now in step 3.
  - Finding (Codex 14; minor): check 6 named `npm run check` in CI, which CI doesn't run as one command. Evidence: `.github/workflows/ci.yml`. Done: fixed, CI's jobs pass.
  - Dropped: 0.

## Decisions made for this ticket

- **Retry limit** (2026-11-18): 4 Qodo rounds, then `needs-help`, and the runner waits for the user.
- **Only Qodo's and the repo owner's comments reach the agent** (2026-11-18), because anyone can comment on a public repo.
- **Qodo is done only after 10 quiet minutes** (2026-11-25): its review comment must name the head and not have been edited for 10 minutes, since Qodo reviews in two passes (PR #22: the head named after 28 seconds, a new finding 2.5 minutes later). It delays a round by at most 10 minutes, and part 3's timer runs every 15.
- **One agent round on every commit Qodo reviews** (2026-11-19), even when Qodo finds nothing. Qodo's summary has no fixed "all clear" form, so the agent decides what's open. The cost is one short `claude` run before `Ready for review by the user.`
- **"Delivery and review" only in a round that commits a fix** (2026-11-26): a round that only answers changes no file, so it can end with nothing to push. Its answers are in its `Agent round N` comment.
- **A draft is marked ready before the wait for Qodo** (2026-11-26), when the user removes `needs-help` from it. Qodo's handling of drafts isn't known, and a PR ready for review is the case it's known to review.
- **A push to the branch during a round drops the round** (2026-11-26): no report, push, or replies about a head that's gone. The work is saved in the run folder, the next run runs a round on the new head, and the dropped round counts toward the 4.
