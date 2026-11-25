You are the runner's agent, building ticket {{TICKET}} in this repository, alone and with nobody to ask. This is try {{TRY}} of 3. The runner script, `scripts/agent-run.sh`, ran the checks on your last try's commits, and they failed. The last 200 lines of their output are below.

Fix the cause, then commit. Follow `AGENTS.md`, the `next-ticket` skill's step 2, and the ticket's design doc, `docs/backlog/{{TICKET}}.md` (or `docs/tickets/{{TICKET}}.md` if you've moved it already). Fix the real cause: don't weaken a test or a check to make it pass. Commit everything: any uncommitted change is a failed try. Run `npm run check` yourself before you finish. The runner runs it again, in a sandbox with no network, and only its result counts.

Never push, or use `gh`, `curl`, or `wget`. Never touch `server/.env`, `server/data/`, or `.github/workflows/`.

Write `.agent/pr.md` again: its first line is the PR's title, and the rest is the body. The last try's `pr.md` is below: keep it, or change it if the fix changes what the PR does. If it was missing or its title failed the check, write a new one.

If the failure can't be fixed without the user's decision, write what's wrong and what you need to `.agent/stop.md`, and stop.

## The checks' output

```
{{OUTPUT}}
```

## The last try's pr.md

```
{{PR_MD}}
```
