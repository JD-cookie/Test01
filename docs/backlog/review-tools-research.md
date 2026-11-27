# Research: catching more before asking Qodo

Status: research, 2026-11-26. Not a ticket: it proposes the backlog items listed at the end, which each get refined on their own. It replaces the idea "Code reviews by our own agents".

## The question

Qodo's reviews are useful, and the user now pays for them, but they're expensive, and the pace of PRs will grow as the runner takes over. So: which free checks, and which reviews by the agents the user already pays a flat rate for (Claude Code, Codex, and opencode), can catch the obvious things first, so that Qodo is asked less often?

Read only, from the tools' docs and this machine's CLIs. Nothing was installed, and no review was run.

## Where Qodo's work comes from today

- **Every push is reviewed again.** Qodo's portal setting "Review every push" is on by default, and "updates the existing review comment on every new commit pushed" ([portal configuration](https://docs.qodo.ai/install-and-configure/configuration-overview/portal-configuration)). PR #22 had 9 pushes, and Qodo reviewed each one (its comment's edit history), in two passes each.
- **Its review trigger can be manual.** The Workflow tab's "Code review trigger" has "Manual only: Reviews run only when triggered manually using `/agentic_review`", besides "Published PRs" (the default) and "Draft and published PRs". "Review every push" is off under "Manual only". In `.pr_agent.toml`, removing `/agentic_review` from `pr_commands` does the same ([use Qodo in PRs](https://docs.qodo.ai/code-review/use-qodo-in-prs), [configuration reference](https://docs.qodo.ai/install-and-configure/configuration-overview/configuration-and-command-reference)). The PR summary has its own trigger (`/agentic_describe`).
- **Auto skips some changes.** On PR #24, Qodo answered `/agentic_review` on a docs-only push with "Qodo did not complete this review — the change was judged trivial". Its docs don't define trivial. The blog says skipping is "reserved for generated files like lockfiles, comment fixes, and pure formatting" ([adaptive router](https://www.qodo.ai/blog/building-an-adaptive-router-for-code-review-depth/)), and `override_effort` in `.pr_agent.toml` forces a fixed depth ([control review effort](https://docs.qodo.ai/code-review/use-qodo-in-prs/control-review-effort)). Forcing it would spend more on the changes that matter least, so it isn't proposed.
- **Credits:** none of Qodo's pages read say what one review costs, or whether the summary counts.

So the biggest saving isn't a tool: it's asking Qodo once per PR, at the end, instead of on every push.

## Free checks (no AI, no cost)

What the repo runs today: the server's typecheck and tests, the app's typegen, lint, and typecheck, the scripts' tests, commitlint, and actionlint by hand before workflow changes (`AGENTS.md`). None of these is installed on this machine: `shellcheck`, `gitleaks`, `lychee`, `zizmor`, `knip` (checked with `which`, 2026-11-26).

| Tool | Catches | Fits here because |
|---|---|---|
| [ShellCheck](https://www.shellcheck.net/) | Shell bugs: unquoted variables, unchecked exit codes, `[` mistakes, subshell traps | 5 scripts, about 2,900 lines of bash (`scripts/`), plus the husky hooks. Several findings in PR #22's review rounds were shell details. Some are the kind ShellCheck flags (exit codes); others aren't (`awk -v` turning `\n` into a new line). |
| [zizmor](https://www.thoughtworks.com/radar/tools/zizmor) | GitHub Actions security: template injection, broad permissions, unpinned actions, `persist-credentials` | It checks most of AGENTS.md rule 5 by machine. actionlint checks correctness; zizmor is "security-focused" and the two are run together elsewhere ([WordPress's workflow standards](https://developer.wordpress.org/coding-standards/wordpress-coding-standards/github-actions/)). |
| [gitleaks](https://github.com/gitleaks/gitleaks) | Secrets in commits | The repo is public, and AGENTS.md says never commit secrets. A pre-commit and CI check catches it before GitHub does. |
| [lychee](https://github.com/lycheeverse/lychee) | Broken links in Markdown | The docs are the spec and link to each other constantly; rule 3 depends on stable links. Its offline mode checks only local links, with no network. |
| [knip](https://knip.dev/) | Unused files, exports, and dependencies in TypeScript | Useful later. Expo Router's routes are files that look unused to it, so it needs entry configuration first ([knip docs](https://knip.dev/)). Not proposed now. |

## Reviews on the flat-rate subscriptions

All three CLIs on this machine have a review mode already, so no review skill needs writing:

- **Claude Code `/code-review`** (2.1.332 here): reviews the branch against its upstream, a PR number, a branch range, or a path, at effort `low` to `max`. "Without `--fix`, the review's instructions ask Claude for a report only." It runs with `-p` too, "waits for the review and includes the findings in the response", and "counts toward your plan's usage" like the rest of the session, so it uses the subscription, not an API key ([local code review](https://code.claude.com/docs/en/code-review-local)).
- **Codex `codex review`** (0.172.0 here): `--base <branch>`, `--uncommitted`, `--commit <sha>`, and custom instructions as the prompt (`codex review --help`). It "reads the selected diff and reports prioritized, actionable findings without changing your working tree" ([Codex code review](https://learn.chatgpt.com/docs/code-review.md?surface=cli)). It writes to stdout: this version has no `-o` or `--json` for `review`.
- **opencode** (2.4.1 here): no built-in review, but a custom command is a Markdown file in `.opencode/commands/`, and can inject `git diff` output into its prompt ([opencode commands](https://opencode.ai/docs/commands)). Run with the read-only `plan` agent, as `refine-ticket` already does.

The `refine-ticket` skill already runs Codex and opencode as read-only reviewers in a throwaway clone, with a prompt that asks for evidence, and drops findings without it. In 6 rounds on ticket 0009 they made 107 findings and none was dropped. That setup, pointed at a PR's diff, is the starting point.

## Looked at and not proposed

- **PR-Agent** ([The-PR-Agent/pr-agent](https://github.com/qodo-ai/pr-agent), MIT, donated by Qodo and now community-owned): a self-hosted reviewer that runs in GitHub Actions or Docker, with any model LiteLLM reaches, Ollama included. Every example uses an API key, so it would bill per token instead of using the flat-rate subscriptions.
- **Qodo's own skills** ([qodo-ai/qodo-skills](https://github.com/qodo-ai/qodo-skills), MIT): `qodo-review` is a local review through the Qodo CLI, which needs `qodo login`. It's another way of using Qodo, not a way around it.
- **Claude Code's GitHub Action** (`anthropics/claude-code-action`): can run on the subscription, with a token from `claude setup-token` ([GitHub Actions](https://code.claude.com/docs/en/github-actions)). But it puts a subscription token in this public repo's secrets and runs in the cloud, while the runner already runs locally with all three CLIs.
- **`requesting-code-review` from obra/superpowers:** dispatches a reviewer subagent. Tessl's check found it references a `code-reviewer.md` that isn't in the bundle ([Tessl](https://tessl.io/registry/skills/github/obra/superpowers/requesting-code-review)). The `refine-ticket` setup is further along.

## Proposed backlog items

Each is small and stands on its own. In the order I'd build them:

1. **Free static checks in CI and pre-commit:** ShellCheck on `scripts/` and `.husky/`, zizmor on `.github/workflows/`, gitleaks on commits, and lychee offline on `docs/`, each with its findings on today's code fixed or listed. They run in the `pre-commit` hook on the staged parts, as the other checks do, and in CI. A refinement may split it by tool.
2. **Agent reviews of a PR on our subscriptions:** one script runs Codex (`codex review --base main`), Claude Code (`claude -p "/code-review medium"`), and opencode once with **each** of its candidate models (`glm-5.3`, `kimi-k3.1-pro`, and `deepseek-v4-pro` today, from `refine-ticket`'s `reviewers.md`), each read-only in a throwaway clone, in parallel, on the same diff with the same instructions. It writes one report of their findings with evidence, for the user's sessions and for the runner. Each PR adds a row per reviewer to a results table: kept, answered, dropped, and **only this one** (kept findings no other reviewer made). The opencode models are cheap, so running all three costs little, and running them on the same diff makes the comparison fair: `refine-ticket` today rotates one opencode model per refinement, so each model has seen different tickets. Over a few weeks the table shows which reviewers find things the others miss, and which can be dropped (the user's idea, 2026-11-26). The same change could apply to `refine-ticket`'s rounds. Not checked yet: whether the ollama-cloud plan allows three runs at once.
3. **Ask Qodo once per PR:** Qodo's trigger set to "Manual only" (a task for the user, in the portal), and the `next-ticket` skill, and later the runner, posts `/agentic_review` once the free checks and the agents' reviews are clean. `AGENTS.md`'s "PRs get a Qodo review" stays true: one review, at the end. Its Qodo findings get one more round. The skill also says how to read Qodo's skip ("judged trivial") and its notices (`billing-blocked`).

Then ticket 0009 (the runner's review rounds) is redesigned on 2 and 3: the agents' reviews and CI in each round, Qodo once at the end. PR #24, which marks the current design ready, is held open until then (the user's decision, 2026-11-26).
