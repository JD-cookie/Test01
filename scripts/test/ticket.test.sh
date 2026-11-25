#!/usr/bin/env bash
# Tests for scripts/ticket.sh: acceptance checks 1 to 14 and 17 to 22 of
# docs/features/0008-ticket-system.md (15 is in agent-run.test.sh, and 16 is by reading).
#
#   npm run test:scripts        (or: bash scripts/test/ticket.test.sh)
#
# Each case runs the real script in a scratch clone of a scratch bare origin, whose main has a
# backlog, docs/tickets/README.md, and docs/README.md that the case writes. Nothing reaches the
# network: GIT_ALLOW_PROTOCOL=file.
#
# Prints "ok N" for each acceptance check that passes, and "not ok N …" with the reasons
# otherwise. Exits 1 if any failed.
set -uo pipefail

repo=$(cd "$(dirname "$0")/../.." && pwd)
script=$repo/scripts/ticket.sh

# Git sets GIT_DIR, GIT_INDEX_FILE, and others while it runs a hook, such as the pre-commit hook
# that runs these tests. Left set, every git command below would act on the repo being committed,
# so clear them all, and check that a fresh folder isn't in a repo.
for v in $(env | sed -n 's/^\(GIT_[A-Z_]*\)=.*/\1/p'); do
  [ "$v" = GIT_EXEC_PATH ] || unset "$v"
done
top=$(mktemp -d)
trap 'rm -rf "$top"' EXIT
if git -C "$top" rev-parse --git-dir >/dev/null 2>&1; then
  echo "not ok - a fresh folder looks like it's inside a git repo; refusing to run"
  exit 1
fi
export GIT_ALLOW_PROTOCOL=file GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
unset TICKET_AGENT GIT_CONFIG_COUNT
failures=0
problems=()

note() { problems+=("$*"); }
expect() { # expect <description> <command…>: records a problem if the command fails
  local what=$1; shift
  "$@" >/dev/null 2>&1 || note "$what"
}
result() { # result <check number> <name>
  if [ "${#problems[@]}" -eq 0 ]; then
    echo "ok $1 - $2"
  else
    echo "not ok $1 - $2"
    printf '  - %s\n' "${problems[@]}"
    if [ -f "${T:-}/out" ]; then
      echo "  the last run (exit $rc) printed:"
      sed 's/^/    /' "$T/out" "$T/err" | tail -n 8
    fi
    failures=$((failures + 1))
  fi
  problems=()
}

# ---- The scratch setup ---------------------------------------------------------------------

# A numbered row: row <NNNN-slug> <title> <status> [notes]
row() { printf '| %s | [%s](%s.md) | Dev tooling | %s | %s |\n' "${1%%-*}" "$2" "$1" "$3" "${4:-}"; }
# An unnumbered row, plain or linked: other <title> [status] / linked <slug> <title> [status]
other() { printf '|  | %s | Dev tooling | %s | Not ready. |\n' "$1" "${2:-designed}"; }
linked() { printf '|  | [%s](%s.md) | Dev tooling | %s | Not ready. |\n' "$2" "$1" "${3:-designed}"; }
# A built ticket's row in docs/tickets/README.md, and a feature's in docs/README.md.
built() { printf '| 0099 | [%s](0099-x.md) | #1 | spec |\n' "$1"; }
feature() { printf '| [%s](features/0001-x.md) | What it does |\n' "$1"; }

# setup: makes $T with origin.git, from the files the case wrote first in $T/seed:
#   $T/rows      the backlog's rows (a design doc is made for every numbered row)
#   $T/tickets   docs/tickets/README.md's rows, or no file for no docs/tickets/README.md
#   $T/features  docs/README.md's Features rows, or no file for no docs/README.md
# Then clones it as the agent's checkout, $T/w.
new_case() { T=$(mktemp -d "$top/case.XXXX"); : >"$T/rows"; rc=0; rm -f "$T/out"; }
setup() {
  local seed=$T/seed
  git init -q -b main "$seed"
  mkdir -p "$seed/docs/backlog"
  {
    printf '# Backlog\n\n| # | Item | Area | Status | Notes |\n|---|---|---|---|---|\n'
    cat "$T/rows"
  } >"$seed/docs/backlog/README.md"
  awk -F'|' '$2 ~ /[0-9]/ && match($3, /\]\([^)]*\.md\)/) { print substr($3, RSTART + 2, RLENGTH - 3) }' "$T/rows" |
    while read -r doc; do echo "# Design of $doc" >"$seed/docs/backlog/$doc"; done
  if [ -f "$T/tickets" ]; then
    mkdir -p "$seed/docs/tickets"
    { printf '# Tickets\n\n| # | Ticket | PR | Spec docs changed |\n|---|---|---|---|\n'; cat "$T/tickets"; } >"$seed/docs/tickets/README.md"
  fi
  if [ -f "$T/features" ]; then
    { printf '# Docs\n\n## Features\n\n| Feature | What |\n|---|---|\n'; cat "$T/features"; } >"$seed/docs/README.md"
  fi
  echo seed >"$seed/file.txt"
  git -C "$seed" add -A
  git -C "$seed" commit -q -m "chore: seed"
  git clone -q --bare "$seed" "$T/origin.git"
  git clone -q "$T/origin.git" "$T/w"
}

# run <args…>: runs ticket.sh in the checkout; exit code in $rc, stdout in $T/out, stderr in $T/err.
run() {
  rc=0
  (cd "$T/w" && sh "$script" "$@") >"$T/out" 2>"$T/err" || rc=$?
}
out_is() { [ "$(cat "$T/out")" = "$1" ]; }
err_has() { grep -qF -- "$1" "$T/err"; }
origin_has() { git -C "$T/origin.git" rev-parse -q --verify "refs/heads/$1" >/dev/null; }
local_has() { git -C "$T/w" rev-parse -q --verify "refs/heads/$1" >/dev/null; }
no_branch() { ! origin_has "$1" && ! local_has "$1"; }
branches() { git -C "$T/origin.git" for-each-ref --format='%(refname:short)' refs/heads | sort | tr '\n' ' '; }

# on_main <command>: runs a shell command in a fresh clone of origin's main, then commits and
# pushes what it changed, as a merged PR would.
on_main() {
  local m=$T/m
  rm -rf "$m"
  git clone -q "$T/origin.git" "$m"
  (cd "$m" && sh -c "$1")
  git -C "$m" add -A
  git -C "$m" commit -q -m "docs: change main"
  git -C "$m" push -q origin main
}
# Somebody else's claim branch on origin.
claim_elsewhere() {
  local c=$T/c
  rm -rf "$c"
  git clone -q "$T/origin.git" "$c"
  git -C "$c" switch -q -c "$1"
  echo other >>"$c/file.txt"
  git -C "$c" commit -q -am "chore(repo): claim ticket $1"
  git -C "$c" push -q origin "$1"
}
# The claim commit on origin is the checkout's branch, and its parent is main.
claimed_ok() {
  origin_has "$1" && local_has "$1" &&
    [ "$(git -C "$T/origin.git" rev-parse "$1")" = "$(git -C "$T/w" rev-parse "$1")" ] &&
    [ "$(git -C "$T/origin.git" rev-parse "$1^")" = "$(git -C "$T/origin.git" rev-parse main)" ]
}

# ---- 1. Waiting ----------------------------------------------------------------------------

new_case
row 0012-thing "Do a thing" ready "Blocked by: Build the base. Then do it." >>"$T/rows"
other "Build the base" >>"$T/rows"
built "Something else" >"$T/tickets"
setup
run list
expect "list exits 0 (was $rc)" [ "$rc" -eq 0 ]
expect "list prints the waiting line" out_is "0012-thing  waiting on: Build the base"
run claim next tester
expect "claim next exits 3 (was $rc)" [ "$rc" -eq 3 ]
expect "claim next makes no branch" no_branch 0012-thing
run claim 0012-thing tester
expect "claim exits 2 (was $rc)" [ "$rc" -eq 2 ]
expect "claim says why" err_has "ticket: 0012-thing is waiting on: Build the base. It can be claimed once each one is built; one that's not in the backlog or built needs the row fixed on main."
expect "claim makes no branch, local or on origin" no_branch 0012-thing
result 1 "waiting: listed with its blocker, skipped, and refused"

# ---- 2. Built ------------------------------------------------------------------------------

for where in tickets features; do
  new_case
  row 0012-thing "Do a thing" ready "Blocked by: Build the base." >>"$T/rows"
  built "Something else" >"$T/tickets"
  feature "Accounts" >"$T/features"
  if [ "$where" = tickets ]; then built "Build the base" >>"$T/tickets"; else feature "Build the base" >>"$T/features"; fi
  setup
  run list
  expect "$where: list prints ready" out_is "0012-thing  ready"
  run claim next tester
  expect "$where: claim next exits 0 (was $rc)" [ "$rc" -eq 0 ]
  expect "$where: its branch on origin is the claim commit" claimed_ok 0012-thing
done
result 2 "built: in docs/tickets/README.md or docs/README.md, the ticket is free"

# ---- 3. Two blockers, one built ------------------------------------------------------------

new_case
row 0012-thing "Do a thing" ready "Blocked by: Build the base; Build the roof." >>"$T/rows"
other "Build the roof" >>"$T/rows"
built "Build the base" >"$T/tickets"
feature "Accounts" >"$T/features"
setup
run list
expect "list names only the one not built" out_is "0012-thing  waiting on: Build the roof"
result 3 "two blockers, one built: only the other is named"

# ---- 4. Unknown ----------------------------------------------------------------------------

new_case
row 0012-thing "Do a thing" ready "Blocked by: Ghost." >>"$T/rows"
built "Build the base" >"$T/tickets"
feature "Accounts" >"$T/features"
setup
run list
expect "list marks it unknown" out_is "0012-thing  waiting on: Ghost (not in the backlog or built)"
run claim next tester
expect "claim next exits 3 (was $rc)" [ "$rc" -eq 3 ]
expect "claim next makes no branch" no_branch 0012-thing
run claim 0012-thing tester
expect "claim exits 2 (was $rc)" [ "$rc" -eq 2 ]
expect "claim names it as unknown" err_has "is waiting on: Ghost (not in the backlog or built). It can be claimed"
result 4 "unknown: waiting, never claimed"

# ---- 5. Order ------------------------------------------------------------------------------

new_case
row 0012-thing "Do a thing" ready "Blocked by: Build the base." >>"$T/rows"
row 0013-other "Do another" ready "Free." >>"$T/rows"
other "Build the base" >>"$T/rows"
setup
run claim next tester
expect "claim next exits 0 (was $rc)" [ "$rc" -eq 0 ]
expect "it claims the free one" claimed_ok 0013-other
expect "not the waiting one" no_branch 0012-thing
result 5 "order: a waiting ticket above a free one, the free one is claimed"

# ---- 6. Row gone but not in the index ------------------------------------------------------

new_case
row 0012-thing "Do a thing" ready "Blocked by: Build the base." >>"$T/rows"
other "Build the base" >>"$T/rows"
built "Something else" >"$T/tickets"
feature "Accounts" >"$T/features"
setup
on_main "grep -v '^|  | Build the base |' docs/backlog/README.md >x && mv x docs/backlog/README.md"
run list
expect "list marks it unknown" out_is "0012-thing  waiting on: Build the base (not in the backlog or built)"
run claim next tester
expect "claim next exits 3 (was $rc)" [ "$rc" -eq 3 ]
result 6 "a blocker whose row is gone but isn't listed as built is unknown"

# ---- 7. Notes after the list ---------------------------------------------------------------

new_case
row 0012-thing "Do a thing" ready "Blocked by: Alpha; Beta. Part 2 of 3. Gamma; Delta." >>"$T/rows"
row 0013-other "Do another" ready "See the plan. Blocked by: Ghost." >>"$T/rows"
other "Alpha" >>"$T/rows"
other "Beta" >>"$T/rows"
setup
run list
expect "list reads Alpha and Beta only, and no blockers for the other" out_is "0012-thing  waiting on: Alpha; Beta
0013-other  ready"
result 7 "notes after the list are not blockers, nor a later 'Blocked by'"

# ---- 8. Linked blocker row -----------------------------------------------------------------

new_case
row 0012-thing "Do a thing" ready "Blocked by: Build the \`base\`" >>"$T/rows"
linked base "Build the \`base\`" >>"$T/rows"
setup
run list
expect "list finds the linked row" out_is "0012-thing  waiting on: Build the \`base\`"
result 8 "a blocker whose row links its doc is found as not built"

# ---- 9. No index ---------------------------------------------------------------------------

new_case
row 0012-thing "Do a thing" ready "Nothing blocks it." >>"$T/rows"
setup
run list
expect "list prints ready (exit $rc)" out_is "0012-thing  ready"
run claim next tester
expect "claim next exits 0 (was $rc)" [ "$rc" -eq 0 ]
expect "the claim is made" claimed_ok 0012-thing
result 9 "no docs/tickets/README.md and no blocked rows: as before"

# ---- 10. Failed read -----------------------------------------------------------------------

new_case
row 0012-thing "Do a thing" ready "Blocked by: Ghost." >>"$T/rows"
row 0013-other "Do another" ready "" >>"$T/rows"
feature "Accounts" >"$T/features"
setup
run list
expect "list exits 2 (was $rc)" [ "$rc" -eq 2 ]
expect "list says what it couldn't read" err_has "couldn't read docs/tickets/README.md"
expect "list prints no ready line" bash -c "! grep -q ready '$T/out'"
result 10 "a failed read of docs/tickets/README.md is exit 2, never a free ticket"

# ---- 11. Blocker added after the claim -----------------------------------------------------

new_case
row 0012-thing "Do a thing" ready "Nothing yet." >>"$T/rows"
setup
run claim 0012-thing tester
expect "the claim exits 0 (was $rc)" [ "$rc" -eq 0 ]
on_main "sed 's/| Nothing yet. |/| Blocked by: Build the base. |/' docs/backlog/README.md >x && mv x docs/backlog/README.md &&
  printf '|  | Build the base | Server | idea | |\n' >>docs/backlog/README.md"
run verify 0012-thing
expect "verify exits 5 (was $rc)" [ "$rc" -eq 5 ]
expect "verify says why" err_has "ticket: the claim is yours, but on main 0012-thing is now waiting on: Build the base. Don't build it: ask the user. Leave the branch; only the user releases a claim."
expect "the branch stays on origin" origin_has 0012-thing
# The same, with a blocker that has no row and no docs/tickets/README.md to check it in: the
# blockers can't be read after a won claim, which is exit 4 (run verify), not 2 (nothing made).
new_case
row 0012-thing "Do a thing" ready "Nothing yet." >>"$T/rows"
setup
run claim 0012-thing tester
expect "the second claim exits 0 (was $rc)" [ "$rc" -eq 0 ]
on_main "sed 's/| Nothing yet. |/| Blocked by: Ghost. |/' docs/backlog/README.md >x && mv x docs/backlog/README.md &&
  rm -f docs/tickets/README.md"
run verify 0012-thing
expect "an unreadable blocker list after the claim: verify exits 4 (was $rc)" [ "$rc" -eq 4 ]
expect "it says the claim is yours and to verify" err_has "ticket: the claim is yours, but the blockers of 0012-thing on main couldn't be read (see above). Run: scripts/ticket.sh verify 0012-thing"
expect "the branch stays on origin" origin_has 0012-thing
result 11 "a blocker added after the claim: verify exits 5, or 4 if the blockers can't be read"

# ---- 12. Unchanged cases -------------------------------------------------------------------

new_case
row 0012-thing "Do a thing" ready "Blocked by: Build the base." >>"$T/rows"
row 0013-other "Do another" ready "Blocked by: Build the base." >>"$T/rows"
printf '| 0014 | [Odd one](0015-odd.md) | Dev tooling | ready | Blocked by: Build the base. |\n' >>"$T/rows"
row 0016-last "Last one" ready "Blocked by: Build the base." >>"$T/rows"
built "Build the base" >"$T/tickets"
feature "Accounts" >"$T/features"
setup
claim_elsewhere 0012-thing
on_main "git rm -q docs/backlog/0013-other.md"
run list
expect "list prints the states of today (exit $rc)" out_is "0012-thing  claimed (branch exists on origin)
0013-other  not claimable: docs/backlog/0013-other.md is missing on main
0015-odd  not claimable: the row's # column doesn't match the doc's number. Fix the row on main
0016-last  ready"
result 12 "built blockers: claimed, missing doc, and mismatch lines are unchanged"

# ---- 13. Empty entries ---------------------------------------------------------------------

new_case
row 0012-thing "Do a thing" ready "Blocked by: ." >>"$T/rows"
row 0013-other "Do another" ready "Blocked by: Alpha; ; Beta" >>"$T/rows"
row 0014-third "Third" ready "Blocked by:" >>"$T/rows"
row 0015-fourth "Fourth" ready "Blocked By: Alpha." >>"$T/rows"
row 0016-fifth "Fifth" ready "Blocked by:Alpha" >>"$T/rows"
row 0017-sixth "Sixth" ready "blocked by Alpha and Beta." >>"$T/rows"
built "Alpha" >"$T/tickets"
built "Beta" >>"$T/tickets"
feature "Accounts" >"$T/features"
setup
run list
expect "list shows each as waiting on an empty entry (exit $rc)" out_is '0012-thing  waiting on: (an empty entry in "Blocked by")
0013-other  waiting on: (an empty entry in "Blocked by")
0014-third  waiting on: (an empty entry in "Blocked by")
0015-fourth  waiting on: (a "Blocked by" not written as "Blocked by: <title>; <title>")
0016-fifth  waiting on: (a "Blocked by" not written as "Blocked by: <title>; <title>")
0017-sixth  waiting on: (a "Blocked by" not written as "Blocked by: <title>; <title>")'
run claim next tester
expect "claim next exits 3 (was $rc)" [ "$rc" -eq 3 ]
expect "no branch is made" [ "$(branches)" = "main " ]
result 13 "empty entries, and a misspelled 'Blocked by': one unknown blocker, so the ticket waits"

# ---- 14. Waiting and claimed ---------------------------------------------------------------

new_case
row 0012-thing "Do a thing" ready "Blocked by: Build the base." >>"$T/rows"
other "Build the base" >>"$T/rows"
setup
claim_elsewhere 0012-thing
run list
expect "list prints the waiting line" out_is "0012-thing  waiting on: Build the base"
run claim 0012-thing tester
expect "claim exits 2, not 3 (was $rc)" [ "$rc" -eq 2 ]
expect "no local branch" bash -c "! git -C '$T/w' rev-parse -q --verify refs/heads/0012-thing"
result 14 "waiting and claimed: shown as waiting, refused with exit 2"

# ---- 17. list's states ---------------------------------------------------------------------

new_case
row 0012-thing "Do a thing" ready >>"$T/rows"
row 0013-other "Do another" ready >>"$T/rows"
row 0014-third "Third" ready >>"$T/rows"
printf '| 0015 | [Odd one](0016-odd.md) | Dev tooling | ready | |\n' >>"$T/rows"
linked designed-one "Designed one" >>"$T/rows"
other "An idea" idea >>"$T/rows"
row 0017-later "Later" designed >>"$T/rows"
setup
claim_elsewhere 0013-other
on_main "git rm -q docs/backlog/0014-third.md"
run list
expect "list prints each state (exit $rc)" out_is "0012-thing  ready
0013-other  claimed (branch exists on origin)
0014-third  not claimable: docs/backlog/0014-third.md is missing on main
0016-odd  not claimable: the row's # column doesn't match the doc's number. Fix the row on main"
result 17 "list's states; designed and idea rows print nothing"

# ---- 18. A won claim -----------------------------------------------------------------------

new_case
row 0012-thing "Do a thing" ready "A note." >>"$T/rows"
setup
run claim 0012-thing tester
expect "exit 0 (was $rc)" [ "$rc" -eq 0 ]
id=$(sed -n 's/^claimed 0012-thing (claim \([0-9a-f]\{8\}\)) on branch 0012-thing$/\1/p' "$T/out")
expect "prints the claim with its id" [ -n "$id" ]
expect "origin's branch is the local one, on main" claimed_ok 0012-thing
expect "the checkout is on the branch" [ "$(git -C "$T/w" symbolic-ref --short HEAD)" = 0012-thing ]
expect "only the backlog changed" [ "$(git -C "$T/origin.git" diff --name-only main 0012-thing)" = docs/backlog/README.md ]
expect "only the row's status changed" bash -c "git -C '$T/origin.git' diff -U0 main 0012-thing -- docs/backlog/README.md | grep '^[-+]|' | sed 's/([^)]*,[^)]*)/(…)/' | grep -c . | grep -qx 2 &&
  git -C '$T/origin.git' show 0012-thing:docs/backlog/README.md | grep -Eq '^\| 0012 \| \[Do a thing\]\(0012-thing.md\) \| Dev tooling \| in progress \(claim $id, tester, [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}Z\) \| A note. \|$'"
msg=$(git -C "$T/origin.git" log -1 --format=%B 0012-thing)
expect "the message has Claim-Id" grep -qx "Claim-Id: $id" <<<"$msg"
expect "the message has Claimed-By" grep -qx "Claimed-By: tester" <<<"$msg"
result 18 "a won claim: the commit, the push, and the message"

# ---- 19. Already claimed -------------------------------------------------------------------

new_case
row 0012-thing "Do a thing" ready >>"$T/rows"
row 0013-other "Do another" ready >>"$T/rows"
setup
claim_elsewhere 0012-thing
run claim 0012-thing tester
expect "claim exits 3 (was $rc)" [ "$rc" -eq 3 ]
expect "no local branch" bash -c "! git -C '$T/w' rev-parse -q --verify refs/heads/0012-thing"
run claim next tester
expect "claim next exits 0 (was $rc)" [ "$rc" -eq 0 ]
expect "claim next claims the other one" claimed_ok 0013-other
result 19 "already claimed: exit 3, and claim next takes the next one"

# ---- 20. Refused before anything is made ---------------------------------------------------

new_case
row 0012-thing "Do a thing" ready >>"$T/rows"
setup
before=$(branches)
touch "$T/w/untracked.txt"
run claim 0012-thing tester
expect "untracked file: exit 2 (was $rc)" [ "$rc" -eq 2 ]
rm "$T/w/untracked.txt"
run claim 0012-thing "two words"
expect "agent name with a space: exit 2 (was $rc)" [ "$rc" -eq 2 ]
run claim not-a-ticket tester
expect "not NNNN-slug: exit 2 (was $rc)" [ "$rc" -eq 2 ]
run claim 0099-nothing tester
expect "no numbered row: exit 2 (was $rc)" [ "$rc" -eq 2 ]
expect "no new branch on origin" [ "$(branches)" = "$before" ]
expect "no new local branch" [ "$(git -C "$T/w" for-each-ref --format='%(refname:short)' refs/heads | tr '\n' ' ')" = "main " ]
result 20 "refused before anything is made: exit 2, no branch"

# ---- 21. Withdrawn after the claim ---------------------------------------------------------

for change in status doc; do
  new_case
  row 0012-thing "Do a thing" ready >>"$T/rows"
  setup
  run claim 0012-thing tester
  expect "$change: the claim exits 0 (was $rc)" [ "$rc" -eq 0 ]
  if [ "$change" = status ]; then
    on_main "sed 's/| ready |/| designed |/' docs/backlog/README.md >x && mv x docs/backlog/README.md"
    msg="ticket: the claim is yours, but on main 0012-thing is now 'designed', not 'ready'."
  else
    on_main "echo more >>docs/backlog/0012-thing.md"
    msg="ticket: the claim is yours, but docs/backlog/0012-thing.md changed on main since the claim."
  fi
  run verify 0012-thing
  expect "$change: verify exits 5 (was $rc)" [ "$rc" -eq 5 ]
  expect "$change: verify says why" err_has "$msg"
  expect "$change: the branch stays on origin" origin_has 0012-thing
done
result 21 "withdrawn or changed after the claim: exit 5, the branch stays"

# ---- 22. verify ----------------------------------------------------------------------------

new_case
row 0012-thing "Do a thing" ready >>"$T/rows"
row 0013-other "Do another" ready >>"$T/rows"
setup
run claim 0012-thing tester
run verify 0012-thing
expect "mine: exit 0 (was $rc)" [ "$rc" -eq 0 ]
expect "mine: says so" out_is "claimed: origin's 0012-thing is your claim commit"
git -C "$T/w" branch -q 0013-other origin/main
run verify 0013-other
expect "none on origin: exit 3 (was $rc)" [ "$rc" -eq 3 ]
claim_elsewhere 0013-other
run verify 0013-other
expect "another's on origin: exit 3 (was $rc)" [ "$rc" -eq 3 ]
expect "another's: says so" err_has "origin's 0013-other is another agent's commit"
result 22 "verify: mine, none, and another agent's"

[ "$failures" -eq 0 ] || exit 1
