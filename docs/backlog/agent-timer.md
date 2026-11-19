# Start the runner on a timer

Status: **designed**. When the user marks it `ready`, it gets a number and this doc is renamed `NNN-agent-timer.md`. It moves to `docs/features/` in the PR that builds it.

This is part 3 of 3, split on 2026-11-19 from "An agent that builds ready tickets on a timer":
1. [A runner that builds a ready ticket into a PR](agent-build.md). **Blocks this one.**
2. [The runner fixes Qodo's findings on its PRs](agent-review-rounds.md). **Blocks this one.**
3. **This one:** the timer.

Terms, the runner, and its checks are part 1's and part 2's. This doc only adds to them.

## Summary

With parts 1 and 2, the user runs `scripts/agent-run.sh` by hand. This part adds a systemd **user timer** that runs it every 15 minutes on the user's machine, installed with one command, so ready tickets are built and taken through Qodo's review without the user starting anything. It's what makes the runner automatic, as Day 4 of the hackathon asks: an agent picks up work from a trigger.

It's for the user, who wants tickets built unattended, and who sets up a new machine with one command.

What doesn't change: what a run does (parts 1 and 2), and the user still marks tickets `ready` and merges.

### Out of scope

- Starting on a label or a push instead of a timer. A timer is enough for one ticket at a time.
- Running in GitHub Actions or the cloud (see "Decisions made for this ticket").
- More than one runner per machine.

## Concepts

- **Timer:** a systemd **user** timer. systemd is Linux's service manager. A user timer runs under the user's own account, with no root. With "linger" on (`loginctl enable-linger`), it runs while the user is logged out too.
- **The runner's copy:** the timer runs a copy of the runner's code that `install` made from the user's checkout, not the checkout itself.

## User-facing behavior

1. Install and start the timer once per machine: `scripts/agent-timer.sh install`. `scripts/agent-timer.sh status` shows the timer and the last run's log. `scripts/agent-timer.sh uninstall` stops it and removes it. `scripts/agent-timer.sh check` checks everything `install` needs, without writing or starting anything.
2. Mark a ticket `ready` as usual. Within 15 minutes, the runner claims it, and from then on follows it through review, as parts 1 and 2 describe.
3. After merging a change to the runner, run `install` again on `main`, to update the copy the timer runs.

## Processing

### The runner's copy

`install` copies `agent-run.sh`, `agent-token.sh`, and `scripts/agent-run/` (the prompts and `settings.json`) to `${XDG_DATA_HOME:-$HOME/.local/share}/jd-cookie-agent/bin/`, and the service runs that copy. Part 1 reads the prompts and settings from beside the running script, so the copy reads its own. The timer then runs what the user installed, from the user's checkout when they ran `install`, and not whatever branch that checkout is on later, nor anything in the runner's clone, which the agent can edit. Running `install` again updates the copy.

### The units

`scripts/agent-timer.sh install` writes two units to `${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/`, runs `systemctl --user daemon-reload`, and `systemctl --user enable --now jd-cookie-agent.timer`:
- `jd-cookie-agent.service`: `Type=oneshot`, `ExecStart=<bin>/agent-run.sh`, the runner's copy. It sets `TimeoutStartSec=4h`, a cap on the whole run, since a run can take three 45-minute agent tries, their checks, and a round (systemd has no start timeout for `Type=oneshot` unless one is set). It writes `XDG_CONFIG_HOME`, `XDG_DATA_HOME`, and `XDG_STATE_HOME` into the unit as `Environment=`, resolved at install time, so the service uses the same folders `install` checked. It sets the `PATH` from the user's shell at install time, so `node`, `npm`, `claude`, and `gh` are found. Probed 2026-11-19: `claude -p` under `systemd-run --user`, with only `PATH` set, answered with the user's Claude login and exited 0. The service's environment has `HOME`, `USER`, `XDG_RUNTIME_DIR`, and `PATH`, but not `XDG_CONFIG_HOME`, `XDG_DATA_HOME`, or `XDG_STATE_HOME`, hence the `Environment=` lines.
- `jd-cookie-agent.timer`: `OnBootSec=5min`, `OnUnitInactiveSec=15min`, so a run starts 15 minutes after the last one ended.

systemd doesn't start a service that's still running, and part 1's lock covers a run started by hand while the timer's is running.

### Checks

`scripts/agent-timer.sh check` runs `agent-run.sh check` (part 1: the tools, the sandbox, `app.pem`'s mode, `APP_CLIENT_ID`, and a token), and also checks that `systemctl` is on `PATH` and that linger is on (`loginctl show-user "$USER" -p Linger`). If linger isn't on, it says to run `sudo loginctl enable-linger "$USER"`, and doesn't fail. It writes and starts nothing. `install` runs it first, and stops if it fails. Running `install` again updates the units and the copy.

`uninstall` disables and stops the timer, and removes both units and the copy. It leaves the clone and the logs. `status` prints `systemctl --user list-timers jd-cookie-agent.timer` and the last run's log. The journal also has each run's output: `journalctl --user -u jd-cookie-agent`.

## Security and configuration

- **Who can trigger it:** only the timer, or the user running the script.
- **What the timer runs:** the copy, which `install` makes from the user's checkout. The user runs `install` on `main`, after merging.
- **Failure modes,** added to parts 1 and 2: a run longer than 4 hours is stopped by systemd, and the next run finds its work where it was left, as after a crash.
- **The project's rules:** rule 3, `docs/devops.md`'s runner section gets the timer in the same PR. The others are as in parts 1 and 2.
- **No new settings:** the interval is in the timer unit, written by `install`.

## Tasks for the user

- **After this PR merges:** run `scripts/agent-timer.sh install` on the machine, on `main`. The builder can't, because it starts the timer, and the timer should run the merged `main`. Check: `scripts/agent-timer.sh status` shows the timer.
- **After that:** the real run (check 3). It happens after this PR merges, so its results go in a follow-up docs PR to this feature's "Delivery and review", as ticket 003's last checks did in PR #12.
- **Already done on this machine (2026-11-18):** linger is on.

## Implementation map

- `scripts/agent-timer.sh` (new): `check`, `install`, `uninstall`, `status`.
- `scripts/test/agent-run.test.sh`: check 1 below.
- `docs/devops.md`: installing, following, and stopping the timer, in the runner's section.

## Acceptance checks

1. **Timer units:** `scripts/agent-timer.sh install`, with the three XDG folders set to scratch directories and stubs for `systemctl`, `loginctl`, and `gh`, writes both units and the copy in `bin/`. The service has `TimeoutStartSec=4h`, `ExecStart` in `bin/`, and `Environment=` lines with those three folders. `systemd-analyze verify` on the two files exits 0 and prints no line that names either file. `uninstall` removes them. With `app.pem` readable by others (mode `644`), `check` and `install` stop, and write no unit. In `agent-run.test.sh`, printing `ok N`. Probed 2026-11-19 (systemd 259): `verify` exits 0 even for an unknown key, and only prints a warning, hence the check on its output. `--user verify` fails with no login session, as in CI, while plain `verify` works. A missing `ExecStart` program makes it exit 1.
2. **The copy is what runs:** with `install` done and the user's checkout then switched to a branch whose `scripts/agent-run/settings.json` differs, a run started by the service stub gets `--settings` from `bin/`, with the installed content.
3. **The real run** (Day 4 of the hackathon, with the user): with the timer installed and one small ticket `ready` ("Delete expired session rows", ticket 004), the runner claims it, builds it, opens a PR that Qodo reviews, and runs rounds until it reports `Ready for review by the user.` or stops with `needs-help`. Shown by the PR, its comments, and the runner's logs. Record what happened in this doc's "Delivery and review", in a follow-up docs PR (see "Tasks for the user"): who opened the PR (`jd-cookie-agent[bot]`), the checks, Qodo's findings, the rounds and retries, and where the user had to step in. It's the first real run of part 2's rounds. Part 1's real run by hand, on a second small ticket, comes before it (part 1's check 9).
4. `npm run check` passes locally and in CI, and `docs/devops.md`'s runner section has the timer.

## Readiness review

Split on 2026-11-19 from "An agent that builds ready tickets on a timer", after its review round 2. That doc's two review rounds covered this part's design too; their record is in [agent-build.md](agent-build.md#readiness-review). This part hasn't been reviewed on its own yet, and its Definition of Ready hasn't been checked on its own: that's its next refinement, after parts 1 and 2.

Answered questions that apply here (see part 1's record): Q3 (the probe of `claude -p` under `systemd-run --user`: it worked).

## Decisions made for this ticket

- **A systemd user timer on the user's machine, installed by a script** (2026-11-18), so a new machine is set up with one command. Not GitHub Actions: it would need a Claude API key as a secret in a public repo, and it couldn't use the user's Claude login. Not T3 Code's scheduled tasks: nothing would be in the repo to review or reuse.
- **The user starts the timer** (2026-11-18): `install` is a task for the user, after the merge.
