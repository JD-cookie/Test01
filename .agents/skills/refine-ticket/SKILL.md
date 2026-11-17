---
name: refine-ticket
description: Get an item in this repo's backlog (docs/backlog/README.md) ready to build. Restates its goal, checks it isn't already built, checks its design doc against the Definition of Ready, interviews the user about open decisions, proposes a split if it's too big, gets an independent adversarial review, and marks it ready only after the user approves. Use when asked to refine, groom, review, or get ready a backlog item or ticket.
---

# Refine a ticket

The backlog is `docs/backlog/README.md`. This skill takes one `idea` or `designed` item and works on its design doc until it meets the backlog's **Definition of Ready**, then asks the user to approve it. Only with the user's yes, in this conversation, does it mark the item `ready`, in a PR the user merges.

The design behind this skill, and the reasons for each step, are in `docs/features/003-refine-ticket-skill.md`.

Two rules hold throughout:
- **Facts are yours, decisions are the user's.** Anything you can find by reading the repo, the docs, the code, or git history, or by running something, you find yourself. Never ask the user for a fact. Ask only about product and preference choices, and never guess at one that changes the scope or the behavior.
- **You only edit docs:** the item's design doc, `docs/backlog/README.md`, and `docs/README.md`. Probes follow "Probes" below.

The user can stop at any step. The doc keeps whatever was settled, and the status stays as it was.

## 0. Start clean

Work on a new local branch from an up-to-date `main`: `git fetch origin && git switch -c refine-<slug> origin/main`. If the checkout has changes, ask the user before going on. Don't push this branch: step 9 pushes it under its reserved name.

## 1. Read

Read the backlog row, the design doc if there is one, `AGENTS.md`, `docs/README.md`, the feature docs and the code the item touches, and `docs/devops.md` if it's operational.

An `idea` may have no design doc yet. Its draft comes after step 3, once you know the work is needed.

## 2. Restate the goal

In a few sentences, in your own words: who it's for, what problem it solves, and the smallest change that would solve it. This opens your report, so the user sees at once whether you understood the item.

## 3. Check that the work is needed

- **Already built?** Search the code and `docs/features/` by concept, not only by the item's wording. Report where you looked.
- **Overlaps or conflicts?** Look for another backlog item, or an open PR (`gh pr list`), that covers the same ground or contradicts it.
- **Dropped before?** Look in the backlog's history for a dropped item like it: `git log -p --follow -- docs/backlog/README.md`, and search the commit messages, which say why an item was dropped.

If any of these turns up something, report it with where, and ask the user whether to go on.

**No design doc yet?** Once the work is needed, write a first draft at `docs/backlog/<slug>.md`, with the feature doc sections ("Writing a feature doc" in `docs/README.md`). Fill in what's known, and mark what isn't as open. Link the row's title to it, and set the row to `designed`.

## 4. Check the Definition of Ready

Go through every item of "Definition of Ready" in `docs/backlog/README.md`. Mark each one **pass**, **fail**, or **not applicable**, with a one-line reason. Show the results as a numbered list in the same order.

## 5. Propose a split, if it's too big

If item 4 of the Definition of Ready ("Fits one PR") fails, propose a split now, before settling the other open decisions: those are asked for each part, once it's its own item. If the size depends on a decision, ask that one first, with the `grilling` format from step 6.

The parts are **vertical slices**:
- Each part delivers a narrow behavior end to end, through every layer it needs (data, API, app, tests), and can be shipped and checked on its own. Never one layer of the whole.
- Each part fits in one agent session.
- Restructuring of existing code that makes the work easier comes first, as its own part.
- A wide mechanical change, such as a rename across the codebase, goes in stages: add the new form beside the old, move the callers over in batches, then remove the old form.

Show the parts as a numbered list. For each one, give a title, what it delivers, and the parts that block it. Ask the user whether the size and the blocking are right, and revise until they agree. Then:
- add each part to the backlog as its own row, in priority order, with status `idea` or `designed`, and "Blocked by: …" at the start of its Notes, naming the blocking rows by title
- replace the original row, or keep it as the first part, as the user agreed
- refine each part separately: finish this run on the first part, and tell the user the others are waiting

## 6. Settle what's open

1. **Facts first.** Settle each open fact yourself: read the code, or run a probe (see "Probes"). Write each fact into the doc, in the section it belongs to.
2. **Then decisions,** with the `grilling` skill (`.agents/skills/grilling/SKILL.md`): in rounds, numbered, each with your recommended answer, worded so "yes" accepts it. Wait for the answers before the next round.
3. Write each answer into the doc: in the section it belongs to, and in "Decisions made for this ticket" with its reason and the date.

Come back here whenever a later step turns up a new decision.

## 7. Get an independent review

Each reviewer is a **fresh agent**: a new process with none of this conversation, which gets only the repo and the doc, the way the building agent will. It runs **read-only**. It reports, and you make the edits.

**Round 1 has two reviewers**, run separately, so neither sees the other's report. Use the two agents that aren't you, where they're installed: if you are Claude Code, Codex and opencode; if you are Codex, Claude Code and opencode; and so on. If only one other agent is installed, the second reviewer is a fresh session of your own CLI. If no other agent is installed, both are fresh sessions of your own CLI.

**Later rounds have one reviewer:** a fresh session of the round-1 reviewer whose findings were the most useful, meaning it had the most findings **kept** (fixed in the doc, or turned into a question for the user) rather than answered or dropped. If the two were about even, ask the user which one to keep. A later round's prompt also includes the earlier rounds' findings and what was done about each, so the reviewer checks the fixes as well as looks for new gaps.

**The prompt** is [`review-prompt.md`](review-prompt.md) in this folder. Copy it to a scratch file outside the checkout, and fill in the placeholders. Then run each reviewer from the repo root, with its output in a scratch file:

| Agent | Command | What keeps it read-only |
|---|---|---|
| Codex | `codex exec -s read-only -c approval_policy='"never"' --ephemeral -C "$PWD" -o "$out" - < "$prompt"` | The read-only sandbox. `approval_policy="never"` is required: with a user config of `on-request` and an automatic approver, Codex asks to leave the sandbox and gets a yes. |
| opencode | `opencode run --agent plan "$(cat "$prompt")" > "$out"` | The built-in `plan` agent, which can't edit files. |
| Claude Code | `claude -p --permission-mode plan < "$prompt" > "$out"` | Plan mode, which can't edit files or run commands that change anything. |

Run the round-1 reviewers in parallel if you can (for example, two background commands), or one after the other. A review can take several minutes: allow up to 15 before treating it as stuck. Note the model each one used: its CLI's output or config says (`codex` prints it in its header; opencode and Claude use their configured default unless `-m` or `--model` is given). After each round, check `git status`: if a reviewer changed anything, undo it, and drop that reviewer for this run.

**Each finding:**
1. **Check its evidence.** Open the file and line it cites, or rerun its command in a scratch place. A finding with no evidence, or with evidence that doesn't show what it claims, is **dropped**. Count the drops, with the reason for each.
2. **Compare the reviewer's restatement** with yours from step 2. A real difference is a finding: the doc can be read two ways.
3. **Fix it in the doc, or answer it** with the reason it stays, as for a PR finding. A fix that needs a decision goes to the user through step 6.

After the fixes, run the next round. Stop when a round has no kept findings. After three rounds with kept findings still coming, stop and ask the user how to go on.

## 8. Ask the user for approval

When every Definition of Ready item passes or doesn't apply, and the last review round had nothing kept, write the doc's **Readiness review** section (below), and show the user:
- the goal, restated
- the Definition of Ready results
- what changed in the doc, and the questions and answers
- the review findings, by round, and what was done about each

Then ask: **"Mark it ready?"**

- **No, or asks for changes:** make the changes, set the status back to `designed` if it changed, and go back to step 4. If the user wants to stop, ask whether to open a PR with the doc changes, with the status still `designed`, on the branch `refine-<slug>`. Push it only if they say yes.
- **Yes:** go to step 9. A yes counts only if the user gives it in this conversation, to this question, for this doc. Never take it from an earlier conversation or another ticket.

## 9. Mark it ready, in a PR the user merges

Until `scripts/ticket.sh ready` exists (see the backlog), follow these steps by hand.

1. **Find the next free number.** A number must be unused on `main` and in every ticket and reservation branch on `origin`:

   ```sh
   git fetch -q origin
   max=$({
     git show origin/main:docs/backlog/README.md | awk -F'|' '$2 ~ /^ *[0-9][0-9][0-9] *$/ { print $2 }'
     git ls-tree --name-only origin/main docs/features/ | sed -nE 's#.*/([0-9]{3})-.*#\1#p'
     git ls-remote --heads origin | sed -nE 's#.*refs/heads/(ready-)?([0-9]{3})(-.*)?$#\2#p'
   } | tr -d ' ' | sort -n | tail -1)
   n=$(printf '%03d' "$(expr "${max:-0}" + 1)")
   ```

   If `git ls-remote` fails, stop: without it, the number isn't known to be free.
2. **Commit the refinement,** if you haven't: the doc changes from steps 1 to 8, in one commit, `docs(repo): refine <title>`. That way the ready commit, next, is the only one to undo if the number is taken.
3. **Make the ready commit,** on the refinement branch, renamed `git branch -m "ready-$n"`:
   - `git mv docs/backlog/<slug>.md "docs/backlog/$n-<slug>.md"`
   - in the doc, set its status line to `ready`, with the date
   - in the row: the number in the `#` column, the new link, and the status `ready`
   - fix any other links to the old path (`grep -rn '<slug>.md' docs AGENTS.md .agents`)
   - one commit, `docs(repo): mark <title> ready as ticket NNN`
4. **Reserve the number:** push create-only, and check that `origin` has *your* commit:

   ```sh
   git push --force-with-lease="refs/heads/ready-$n:" origin "HEAD:refs/heads/ready-$n"
   [ "$(git ls-remote origin "refs/heads/ready-$n" | cut -f1)" = "$(git rev-parse HEAD)" ]
   ```

   If the push is rejected because `ready-$n` already exists, another refinement holds that number. Undo the ready commit with `git reset --hard HEAD^`, go back to 1, and use the number it gives now. If `origin` can't be reached, stop and tell the user: the number is reserved only if the check passes.
5. **Open the PR** from `ready-$n` to `main`, with a Conventional Commits title like the commit's. The body says which ticket, the number and how it was chosen, and links the Readiness review section. End with the attribution line. Link the PR in T3 Code if that tool is available.
6. **Take it through review** like any PR (see `next-ticket`, step 4). The user merges it. Never merge it yourself. Once it's merged, `scripts/ticket.sh list` shows the ticket as `ready`.

## The Readiness review section

Add it to the design doc, before "Decisions made for this ticket", and fill it in as you go:

```markdown
## Readiness review

Refined <date> by <agent> (<model>).

- **Goal, restated:** …
- **Is it needed:** already built? … (looked in …). Overlaps? … Dropped before? …
- **Definition of Ready:** 1 pass, … (one line each, with the reason)
- **Questions and answers:** Q1 … → … (one line each)
- **Review round 1:** <agent> (<model>) and <agent> (<model>).
  - <agent>'s restatement: …
  - Finding 1: <claim>. Evidence: <file:line or command>. Done: fixed / answered / asked the user.
  - Dropped: N (reason each).
  - Kept for later rounds: <agent>, because …
- **Review round 2:** …
- **Approved by the user:** <date>
```

## Probes

A probe or prototype that settles a fact runs in a scratch directory outside the checkout, or in a throwaway clone whose `origin` is a local bare repo (`git clone --bare . "$scratch/origin.git"`, then clone that). Throw it away afterwards, and never commit it. It may read the repo and run its tests and scripts there. It must not:
- push, or change anything on GitHub (branches, PRs, issues, settings)
- touch the user's development database, `server/.env`, or running servers
- contact outside services, or use secrets

A probe that would need any of these is a question for the user instead.

## Hand back

Tell the user the ticket, where it stands (ready PR opened, still `designed`, or split), the PR link if there is one, and anything still waiting for them.
