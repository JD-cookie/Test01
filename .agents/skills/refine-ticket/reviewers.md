# Reviewer models and how they did

The `refine-ticket` skill (step 7) uses this file to choose opencode's model, and adds a row for every reviewer after each round. Over several refinements, the table shows which agents and models find the most problems that hold up.

## opencode's candidate models

Each refinement's opencode reviewer uses the candidate with the fewest rows in the table below. On a tie, it uses the one higher in this list. A model added here starts with no rows, so the next refinement tries it. Remove a model only when the user decides to.

1. `ollama-cloud/glm-5.3`
2. `ollama-cloud/kimi-k3.1-pro`
3. `ollama-cloud/deepseek-v4-pro`

## Results

One row per reviewer per round. **Kept** findings were fixed in the doc or turned into a question for the user. **Answered** ones were checked and left as they were, with the reason. **Dropped** ones had no evidence, or evidence that didn't show what they claimed.

| Date | Ticket | Round | Agent | Model | Kept | Answered | Dropped |
|---|---|---|---|---|---|---|---|
| 2026-11-18 | Delete expired session rows | 1 | Codex | gpt-6.1-sol | 3 | 0 | 0 |
| 2026-11-18 | Delete expired session rows | 1 | opencode | ollama-cloud/glm-5.3 | 5 | 0 | 1 |
| 2026-11-18 | Delete expired session rows | 2 | opencode | ollama-cloud/glm-5.3 | 4 | 0 | 0 |
| 2026-11-18 | Delete expired session rows | 3 | opencode | ollama-cloud/glm-5.3 | 3 | 0 | 0 |
| 2026-11-18 | Delete expired session rows | 4 | Codex | gpt-6.1-sol | 3 | 0 | 0 |
| 2026-11-18 | Delete expired session rows | 4 | opencode | ollama-cloud/glm-5.3 | 3 | 0 | 0 |
| 2026-11-19 | An agent that builds ready tickets on a timer | 1 | Codex | gpt-6.1-sol | 14 | 0 | 0 |
| 2026-11-19 | An agent that builds ready tickets on a timer | 1 | opencode | ollama-cloud/kimi-k3.1-pro | 14 | 0 | 0 |
| 2026-11-19 | An agent that builds ready tickets on a timer | 2 | Codex | gpt-6.1-sol | 13 | 0 | 1 |
| 2026-11-19 | An agent that builds ready tickets on a timer | 2 | opencode | ollama-cloud/kimi-k3.1-pro | 15 | 0 | 0 |
| 2026-11-19 | A runner that builds a ready ticket into a PR | 3 | Codex | gpt-6.1-sol | 9 | 0 | 0 |
| 2026-11-19 | A runner that builds a ready ticket into a PR | 3 | opencode | ollama-cloud/deepseek-v4-pro | 4 | 0 | 0 |
| 2026-11-19 | A runner that builds a ready ticket into a PR | 4 | Codex | gpt-6.1-sol | 6 | 0 | 0 |
| 2026-11-19 | A runner that builds a ready ticket into a PR | 4 | opencode | ollama-cloud/deepseek-v4-pro | 5 | 0 | 0 |
| 2026-11-19 | A runner that builds a ready ticket into a PR | 5 | Codex | gpt-6.1-sol | 2 | 0 | 0 |
| 2026-11-19 | Keep the spec separate from the ticket history | 1 | Codex | gpt-6.1-sol | 7 | 0 | 0 |
| 2026-11-19 | Keep the spec separate from the ticket history | 1 | opencode | ollama-cloud/kimi-k3.1-pro | 9 | 0 | 0 |
| 2026-11-19 | Keep the spec separate from the ticket history | 2 | Codex | gpt-6.1-sol | 3 | 0 | 0 |
| 2026-11-19 | Keep the spec separate from the ticket history | 2 | opencode | ollama-cloud/kimi-k3.1-pro | 7 | 0 | 0 |
| 2026-11-19 | Keep the spec separate from the ticket history | 3 | Codex | gpt-6.1-sol | 1 | 0 | 0 |
| 2026-11-19 | Keep the spec separate from the ticket history | 3 | opencode | ollama-cloud/kimi-k3.1-pro | 4 | 0 | 0 |
| 2026-11-19 | Keep the spec separate from the ticket history | 4 | Codex | gpt-6.1-sol | 0 | 0 | 0 |
| 2026-11-19 | Keep the spec separate from the ticket history | 4 | opencode | ollama-cloud/kimi-k3.1-pro | 4 | 0 | 0 |
| 2026-11-19 | Keep the spec separate from the ticket history | 5 | Codex | gpt-6.1-sol | 0 | 0 | 0 |
| 2026-11-19 | Keep the spec separate from the ticket history | 5 | opencode | ollama-cloud/kimi-k3.1-pro | 3 | 0 | 0 |
| 2026-11-20 | Keep the spec separate from the ticket history | 6 | Codex | gpt-6.1-sol | 3 | 0 | 0 |
| 2026-11-20 | Keep the spec separate from the ticket history | 6 | opencode | ollama-cloud/kimi-k3.1-pro | 5 | 0 | 0 |
| 2026-11-20 | Keep the spec separate from the ticket history | 7 | Codex | gpt-6.1-sol | 1 | 0 | 0 |
| 2026-11-20 | Keep the spec separate from the ticket history | 7 | opencode | ollama-cloud/kimi-k3.1-pro | 2 | 0 | 1 |
| 2026-11-24 | Mark a blocked ticket `ready` before its blockers are built | 1 | Codex | gpt-6.1-sol | 2 | 0 | 0 |
| 2026-11-24 | Mark a blocked ticket `ready` before its blockers are built | 1 | opencode | ollama-cloud/deepseek-v4-pro | 3 | 1 | 0 |
| 2026-11-24 | Mark a blocked ticket `ready` before its blockers are built | 2 | Codex | gpt-6.1-sol | 0 | 0 | 0 |
| 2026-11-24 | Mark a blocked ticket `ready` before its blockers are built | 2 | opencode | ollama-cloud/deepseek-v4-pro | 0 | 0 | 0 |
| 2026-11-25 | The runner fixes Qodo's findings on its PRs | 1 | Codex | gpt-6.2-sol | 13 | 1 | 0 |
| 2026-11-25 | The runner fixes Qodo's findings on its PRs | 1 | opencode | ollama-cloud/glm-5.3 | 16 | 1 | 0 |
