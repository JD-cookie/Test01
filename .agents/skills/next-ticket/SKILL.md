---
name: next-ticket
description: Pick up the next ready ticket from this repo's backlog (docs/backlog/README.md), claim it so no other agent takes it, build it on its own branch, and take it through its PR and review. Use when asked to work on the backlog, pick up a ticket, or build a numbered backlog item such as 003.
---

# Next ticket

The backlog is `docs/backlog/README.md`. Its "How it works" section defines the statuses and the lifecycle of a ticket. This skill is how an agent carries a ticket through that lifecycle. Several agents may run it at the same time, so the claim step is the only safe way to start one.

## 1. Pick a ticket

```bash
scripts/ticket.sh list
```

It lists `main`'s `ready` tickets in priority order and marks those already claimed, which means their branch exists on `origin`. Take the first one marked `ready`, unless the user named a ticket. If none is free, stop and tell the user. Don't build an `idea` or `designed` item, and don't mark anything `ready` yourself: only the user does that.

## 2. Claim it

```bash
scripts/ticket.sh claim NNN-slug <agent-name>
```

Use a name that tells agents apart, e.g. `claude-<short session id>`. The script:
- creates the branch `NNN-slug` from `origin/main`
- commits the status `in progress (claim <id>, <agent>, <time>)`
- pushes create-only, then checks that `origin` has *its* commit

What the exit codes mean:
- **0:** the ticket is yours, and you're on its branch.
- **3:** another agent got there first. Go back to step 1 and take the next ticket. Never delete or overwrite another agent's branch, and never push to it with `--force`.
- **2:** the ticket isn't `ready`, your checkout has changes (untracked files count), a local branch is in the way, or the claim commit failed. Your checkout is left as it was. Fix the cause or ask the user.
- **4:** `origin` couldn't be reached, so the outcome isn't known. If the script kept your local branch, run `scripts/ticket.sh verify NNN-slug` once `origin` is reachable. It returns 0 if the claim is yours and 3 if it isn't. Otherwise, try the claim again.

## 3. Build it

Read the ticket's design doc, `docs/backlog/NNN-slug.md`, all of it. Its acceptance checks define what "done" means. Also follow `AGENTS.md`: its rules apply to every ticket.

- If the design doc turns out to be wrong or incomplete, don't guess at something big. Ask the user. Small gaps can be decided and written down in the doc.
- In the same branch:
  1. Move the design doc to `docs/features/NNN-slug.md` (`git mv`) and update it to match what was built, including the implementation map.
  2. Add the feature to the Features table in `docs/README.md`.
  3. Delete the ticket's row from `docs/backlog/README.md`. That also removes the claim status.
  4. Fix any links to the old path. Operational changes also go in `docs/devops.md`.
- Commit with Conventional Commits messages, and let the hooks run.
- Run `npm run check` before pushing. Run the Valkey tests too if the change touches rate limiting.

## 4. Open the PR

- **Title:** a Conventional Commits title. The type and scope should match the change, e.g. `feat(server): delete expired session rows`. Use `!` for breaking changes.
- **Body:**
  - Start with `Ticket: NNN-slug (docs/features/NNN-slug.md)`.
  - Then what was built.
  - Then each acceptance check and how it was verified.
  - End with the attribution line.
- Link the PR in T3 Code if that tool is available.

## 5. Take it through review

- After each push, check the PR about 10 minutes later, then again 30 minutes after that if nothing changed. Look for Qodo's review, CI results, and comments.
- Fix each finding, or answer it with the reason it stays. Each fix is a new push, which starts the checks over.
- **Keep the branch up to date with `main`.** Other tickets' PRs edit the same tables: the Features table in `docs/README.md` and the backlog table. When `main` moves on, merge it into your branch with `git fetch origin && git merge origin/main`. Don't rebase, so no force-push is needed. In a table conflict, keep both sides: every merged ticket's feature row stays, and every merged ticket's backlog row stays gone. Then run `npm run check` again and push. Do this before asking the user to merge, too.
- Before the PR is merged, fill in the doc's **Delivery and review** section:
  - which acceptance checks passed, and how
  - what the review found, and what was done about each finding
  - whether anything should change in `AGENTS.md` rules, skills, or the context reviewers get

  If something should change, suggest it to the user rather than changing the rules in the same PR.
- The user merges. Don't merge it yourself.

## 6. Hand back

Tell the user the ticket, the PR link, the check and review status, and anything that needs their decision. Then, if asked to continue, go back to step 1.

If you have to stop partway, push what you have and tell the user. Leave the branch: it still holds the claim. Only the user releases a claim, by deleting the branch.
