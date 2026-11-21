# The runner fixes Qodo's findings on its PRs

Status: **designed**. When the user marks it `ready`, it gets a number and this doc is renamed `NNNN-agent-review-rounds.md`. In the PR that builds it, it moves to `docs/tickets/` (ticket 0006's layout), and that PR edits the runner's spec doc, `docs/features/NNNN-agent-runner.md` (part 1's number), in place.

This is part 2 of 3, split on 2026-11-19 from "An agent that builds ready tickets on a timer":
1. [A runner that builds a ready ticket into a PR](agent-runner.md): the runner, run by hand. **Blocks this one.**
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

- **Round:** one pass of the agent over the review results of one push: Qodo's findings, the owner's comments, and failed CI jobs. It ends with a push, or with "nothing left to fix".
- **The runner's marker:** every comment and reply the runner posts ends with a hidden `<!-- jd-cookie-agent ... -->` marker. It records which commit a round reviewed and pushed, and when it collected the comments (see "The runner's records").
- **Removing `needs-help`:** the user's way to let the runner go on with a PR. It resets the round count.

## User-facing behavior

1. While the runner's PR is open, each round adds two comments from the runner: `Agent round N started`, then `Agent round N` with what it did, and a reply to each inline comment it was given.
2. When it's done, it comments `Ready for review by the user.`
3. If it stops for help, the PR gets the label `needs-help` and a comment that says why. To let it go on, fix what's needed, then remove the label. Removing it resets the round count. A draft PR is marked ready for review when the runner next finishes.
4. Merge, or close the PR, as for any PR.

## Processing

### Changes to part 1

- **"Find its work":** an open PR **without** `needs-help` goes to the review step (below). An open PR with `needs-help` still gets nothing.
- **"Stopping for help"** with a PR open: the same steps 1 and 2, then, instead of opening a PR, a comment with what part 1 puts in the draft's description (the reason, the run folder's path, and the output), then the label `needs-help`. Comment first: if the run dies between the two, the PR has no `needs-help`, and the next run's review step stops again and finishes it.
- **A draft PR:** when the user removes `needs-help` from a draft, the runner marks it ready for review (`gh api graphql`, `markPullRequestReadyForReview`) before it posts `Ready for review by the user.`

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
9. **Checks** as in part 1's build step, 3 tries, with the title check if `pr.md` changed. If they still fail, stop for help, with the output.
10. **Report, push, reply:** post `Agent round N`, with `round.md` and its marker. Then, if the round or the merge made a commit, push. If GitHub refuses it (a workflow change), stop for help. If the title changed and passes the title check, set it (`gh api -X PATCH repos/<owner>/<repo>/pulls/<n>`). Then post each reply as a reply to its comment (`gh api …/pulls/<n>/comments/<id>/replies`), each with the marker `round=N`. Then:
    - **It pushed:** exit. The next run waits for Qodo's review of the new head.
    - **Nothing to push, and CI green:** the round is the last. Mark a draft PR ready for review, and post `Ready for review by the user.` with the marker, once per head commit. If the user or Qodo comments again, a later run runs a round for it.
    - **Nothing to push, and CI red:** stop for help: "CI still fails, and round N changed nothing."

### The agent's files

Added to part 1's list, with the same rules:
- `round.md`: not empty.
- `replies.json`: valid JSON, an array with exactly one object for each inline comment collected in step 3, no more, none twice, each with that comment's numeric `comment_id` and a non-empty `body`.

### The agent

As in part 1, with a third prompt, `scripts/agent-run/round.md`, with the same three rules. The agent still can't read PR comments itself (`gh` is denied): it sees only what the runner collected.

## Security and configuration

- **Untrusted text:** comments by other accounts are never passed to the agent. Qodo's text and the owner's are passed, but the agent can only change files in its clone, and the checks and Qodo's next review see everything it changes.
- **Failure modes,** added to part 1's: Qodo or CI never finishing (the 60-minute limit), a lost push or unposted replies (step 1), a conflict with `main` (step 6), and red CI that a round can't fix (step 10).
- **The project's rules:**
  - Rule 1 (count before you check): a round is recorded on GitHub (`Agent round N started`) before it runs, and counted from there, and only one run works at a time (the lock).
  - Rule 2: the records are on GitHub, in the PR's comments, not in the runner.
  - Rule 3: `docs/devops.md`'s runner section gets the review step in the same PR.
- **No new settings:** the round limit (4) and the wait (60 minutes) are constants at the top of `agent-run.sh`.

## Tasks for the user

None new. Part 1's Qodo setting ("Allow GitHub bot reviews") must be on before the first round can run, since a round waits for Qodo's review.

## Implementation map

- `scripts/agent-run.sh`: the review step, the records, and the changes to part 1.
- `scripts/agent-run/round.md` (new): the round prompt.
- `scripts/test/agent-run.test.sh`: checks 1 to 6 below, with fixtures for Qodo's comments copied from real ones on PRs #10 and #12, which start with a blank line or `<h3>`.
- The runner's spec doc, `docs/features/NNNN-agent-runner.md` (part 1's number): the review step and the changes to part 1, edited in place, with a Changes line.
- `docs/devops.md`: the review step in the runner's section.

## Acceptance checks

All are in `scripts/test/agent-run.test.sh`, on part 1's scratch setup, with the `gh` fixtures' lists long enough to need a second page, and the deciding comment or event on the last one. Each passes when the script prints `ok N`.

1. **Waits for Qodo and CI:** with an open `agent-run` PR whose Qodo review comment names an older commit, a run calls `claude` 0 times and changes nothing. The same with Qodo done and a CI check pending, and with Qodo done and no checks listed at all. With Qodo's "PR Summary" comment naming the head and its review comment an older commit, it still waits. With the push 61 minutes ago, it adds `needs-help`.
2. **Round:** with Qodo's review comment (`Code Review by Qodo`) for the head commit and one new Qodo inline comment, a run calls `claude` once with the round prompt, which contains that comment's text. It posts `Agent round 1 started` before calling `claude`, posts `Agent round 1` with `pushed` naming the new commit, then pushes, then posts the reply from `replies.json` to that comment's id. With a failed CI job, its failed log lines are in the round prompt. With an owner's review body (a review with no inline comment), its text is in the prompt.
   - **Bad agent output:** with `replies.json` not valid JSON, naming a comment id that wasn't collected, naming one twice, or leaving one out, the try fails.
3. **Only Qodo and the owner:** a comment from another account, containing `IGNORE-ME`, is not in the round prompt. One from the owner is, both inline and on the PR itself. A comment by `jd-cookie-agent[bot]`, containing `MINE`, is not.
4. **Round limit and crashes in a round:** with 4 `Agent round N started` comments since the PR opened, a run adds `needs-help` and calls `claude` 0 times, also when some of the 4 have no `Agent round N` after them. With `needs-help` removed after round 4, and nothing else new, the next run runs round 5 as a new round 1. A PR with `needs-help` gets no `claude` call.
   - With `Agent round 1 started` and no `Agent round 1` (a crash during the agent), the next run runs round 2 on the same head, and calls `claude` once.
   - With `Agent round 1` posted, its `pushed` commit in the clone but not on `origin` (a crash before the push), the next run pushes it, and calls `claude` 0 times. With that commit in neither, it adds `needs-help`.
   - With `Agent round 1` posted and pushed but its reply not, the next run posts the reply, and calls `claude` 0 times for it.
   - With an owner comment dated after the round's `cutoff` but before its `Agent round 1` comment, the next run runs a round with it.
   - With an owner comment from before the cutoff, edited after it, and no new commit, the next run runs a round with it.
   - With a round on commit A that pushed commit B, and Qodo's comment edited to name B, the next run runs a round on B.
5. **Done:** with the review comment for the head commit, no round on that head yet, CI green, and the agent stub changing nothing, a run calls `claude` once, posts `Agent round N`, and comments `Ready for review by the user.`, in that same run. A second run calls `claude` 0 times and doesn't comment again.
   - **CI stays red:** with a failed CI job and the agent stub changing nothing, the run adds `needs-help` with "CI still fails, and round N changed nothing." and doesn't post `Ready for review by the user.`
   - **Main moved on:** after `Ready for review by the user.`, with `main` on the bare `origin` one commit ahead of the PR's branch, the next run runs a round, and its push holds a merge of `main`.
   - **A draft PR after `needs-help`:** with `needs-help` removed from a draft PR and the round pushing nothing, the run marks the PR ready for review before it posts `Ready for review by the user.`
   - **A conflict with main:** with a conflicting commit on `main`, the run adds `needs-help` and calls `claude` 0 times.
   - **A workflow change in a round:** with the push stub refusing the round's push, the run adds `needs-help`, and the run folder has `commits.bundle` with the round's merge of `main`.
   - **`stop.md` in a round:** with the agent stub writing `.agent/stop.md`, the run adds `needs-help` with `stop.md` as the comment, and opens no new PR.
6. `npm run check` passes locally and in CI, and `docs/devops.md`'s runner section has the review step.

The first real round is part 3's real run, on ticket 0004. Part 1's real run by hand (its check 9) comes before, but the user takes that PR through review.

## Readiness review

Split on 2026-11-19 from "An agent that builds ready tickets on a timer", after its review round 2. That doc's two review rounds covered this part's design too; their record is in [agent-runner.md](agent-runner.md#readiness-review). This part hasn't been reviewed on its own yet, and its Definition of Ready hasn't been checked on its own: that's its next refinement, after part 1.

Answered questions that apply here (see part 1's record): Q1 (the App, so the runner's comments are told apart by author), Q2 (a round on every commit Qodo reviews), Q4 (a workflow change stops with `needs-help`), Q6 and Q7 (the agent's limits).

## Decisions made for this ticket

- **Retry limit** (2026-11-18): 4 Qodo rounds, then `needs-help`, and the runner waits for the user.
- **Only Qodo's and the repo owner's comments reach the agent** (2026-11-18), because anyone can comment on a public repo.
- **One agent round on every commit Qodo reviews** (2026-11-19), even when Qodo finds nothing. Qodo's summary has no fixed "all clear" form, so the agent decides what's open. The cost is one short `claude` run before `Ready for review by the user.`
