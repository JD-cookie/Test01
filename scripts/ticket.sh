#!/bin/sh
# Backlog tickets: list the ready ones, and claim one so no other agent works on it.
#
#   scripts/ticket.sh list
#   scripts/ticket.sh claim <NNN-slug> [agent-name]
#   scripts/ticket.sh verify <NNN-slug>     # after exit 4: is the claim on origin ours?
#
# A ticket is a row in docs/backlog/README.md with status `ready`, a number, and a design doc
# docs/backlog/<NNN-slug>.md. Its branch is named <NNN-slug>, so every agent knows the name in
# advance. Claiming a ticket means being the one who creates that branch on origin:
#
#   1. The branch must not exist on origin yet.
#   2. Create it from origin/main, with one commit that sets the row's status to
#      `in progress (claim <random id>, <agent>, <time>)`. The random id makes every claim
#      commit unique. Two agents making the same commit would get the same hash, and both
#      pushes would succeed ("Everything up-to-date"), so each would think it won.
#   3. Push with --force-with-lease=refs/heads/<branch>: (an empty lease means "only if the
#      branch doesn't exist"). Git updates the branch atomically, so only one push creates it.
#   4. Check that the branch on origin points at our commit. Only then is the claim ours. A failed
#      push alone isn't proof of a lost race (the reply may have been lost), so the outcome is
#      always decided by what origin holds.
#
# The ticket list is read from origin/main, not the working tree. Claims are visible as
# branches on origin: a claim reaches main's backlog only when its PR merges.
# Releasing a claim means deleting its branch on origin. Only the user does that.
#
# Exit codes: 0 claimed (or listed), 2 usage, dirty checkout, or not a ready ticket,
# 3 already claimed or lost the race, 4 origin unreachable or the outcome unknown: see the message.
set -eu

backlog=docs/backlog/README.md

# Paths here are relative to the repo root, so run from there wherever the script was called from.
root=$(git rev-parse --show-toplevel) || { echo "ticket: not inside a git checkout" >&2; exit 2; }
cd "$root"

die() { code=$1; shift; echo "ticket: $*" >&2; exit "$code"; }

# Prints "<NNN-slug> <status>" for each numbered row of main's backlog.
tickets() {
  git show "origin/main:$backlog" | awk -F'|' '
    $2 ~ /^ *[0-9][0-9][0-9] *$/ {
      if (match($3, /\]\([0-9][0-9][0-9]-[a-z0-9-]+\.md\)/)) {
        slug = substr($3, RSTART + 2, RLENGTH - 6)
        status = $5; gsub(/^ +| +$/, "", status)
        print slug, status
      }
    }'
}

list() {
  git fetch -q origin main || die 4 "couldn't reach origin"
  # Checked before it's filtered: an empty list from a failed lookup would show claimed tickets as free.
  heads=$(git ls-remote --heads origin) || die 4 "couldn't reach origin to list the claimed tickets"
  branches=$(printf '%s\n' "$heads" | sed 's|.*refs/heads/||')
  tickets | while read -r slug status; do
    [ "$status" = ready ] || continue
    if ! git cat-file -e "origin/main:docs/backlog/$slug.md" 2>/dev/null; then
      echo "$slug  not claimable: docs/backlog/$slug.md is missing on main"
    elif printf '%s\n' "$branches" | grep -qx -- "$slug"; then
      echo "$slug  claimed (branch exists on origin)"
    else
      echo "$slug  ready"
    fi
  done
}

# Prints the commit that origin's branch $1 points at, or nothing if there's no such branch.
# Fails only if origin can't be reached, after three tries.
remote_head() {
  tries=0
  while :; do
    if out=$(git ls-remote origin "refs/heads/$1"); then
      printf '%s\n' "$out" | cut -f1
      return 0
    fi
    tries=$((tries + 1))
    [ "$tries" -lt 3 ] || return 1
    sleep 2
  done
}

# Makes the local branch $1 track origin's. Only a convenience: the claim is settled by then,
# so a failure here warns and doesn't change the outcome.
track() {
  if ! { git fetch -q origin "$1" && git branch -q --set-upstream-to="origin/$1" "$1"; }; then
    echo "ticket: the claim is yours, but setting the branch's upstream failed. Later, run: git push -u origin $1" >&2
  fi
}

claim() {
  ticket=$1
  agent=$2
  # Whole-value checks (grep -x would accept a multi-line value if any one line matched), because
  # both values end up in the backlog table.
  case $ticket in
    [0-9][0-9][0-9]-*[!a-z0-9-]* | [0-9][0-9][0-9]-) die 2 "not a ticket name: $ticket (expected NNN-slug)" ;;
    [0-9][0-9][0-9]-*) ;;
    *) die 2 "not a ticket name: $ticket (expected NNN-slug)" ;;
  esac
  case $agent in
    '' | *[!A-Za-z0-9._@-]*) die 2 "agent name may only use letters, digits, and . _ @ -" ;;
  esac
  # Untracked files count too: they would follow the agent onto the ticket branch.
  if [ -n "$(git status --porcelain)" ]; then
    die 2 "commit, stash, or remove your changes first, including untracked files (see git status)"
  fi

  git fetch -q origin main || die 4 "couldn't reach origin"
  status=$(tickets | awk -v t="$ticket" '$1 == t { $1 = ""; sub(/^ /, ""); print }')
  [ -n "$status" ] || die 2 "$ticket isn't a numbered ticket in $backlog on origin/main"
  [ "$status" = ready ] || die 2 "$ticket has status '$status' on origin/main, not 'ready'"
  git cat-file -e "origin/main:docs/backlog/$ticket.md" 2>/dev/null ||
    die 2 "$ticket is ready but its design doc docs/backlog/$ticket.md is missing on origin/main"
  existing=$(remote_head "$ticket") || die 4 "couldn't reach origin"
  [ -z "$existing" ] || die 3 "$ticket is already claimed: the branch exists on origin"
  if git show-ref --quiet "refs/heads/$ticket"; then
    die 2 "a local branch $ticket exists. If it's an old claim attempt, run: scripts/ticket.sh verify $ticket"
  fi

  id=$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')
  when=$(date -u +%Y-%m-%dT%H:%MZ)
  if start=$(git symbolic-ref --quiet --short HEAD); then
    back() { git switch -q "$start"; }
  else
    start=$(git rev-parse HEAD)
    back() { git switch -q --detach "$start"; }
  fi
  git switch -q --no-track -c "$ticket" origin/main || die 2 "couldn't create the branch $ticket"

  # Until the push, nothing exists outside this checkout. On any failure, put the checkout back
  # as it was. The tree was clean before, so the hard reset only drops this script's own edit.
  abandon() { git reset -q --hard; back; git branch -q -D "$ticket"; }

  # Edit the status cell (column 5) of this ticket's row, with the same spacing rules as tickets().
  if ! tmp=$(mktemp); then
    abandon
    die 2 "couldn't create a temporary file"
  fi
  if ! { awk -F'|' -v OFS='|' -v link="](${ticket}.md)" -v claim="in progress (claim $id, $agent, $when)" '
      index($3, link) { s = $5; gsub(/^ +| +$/, "", s); if (s == "ready") $5 = " " claim " " }
      { print }' "$backlog" >"$tmp" && cat "$tmp" >"$backlog"; }; then
    rm -f "$tmp"
    abandon
    die 2 "couldn't write the claim to $backlog"
  fi
  rm -f "$tmp"
  if git diff --quiet; then
    abandon
    die 2 "couldn't find the status cell of $ticket in $backlog"
  fi
  if ! { git add "$backlog" && git commit -q -m "chore(repo): claim ticket $ticket" -m "Claim-Id: $id
Claimed-By: $agent"; }; then
    abandon
    die 2 "the claim commit failed (see above), so nothing was pushed. If the commit-msg hook is missing its tools, run npm install in the repo root."
  fi
  mine=$(git rev-parse HEAD)

  # A failed push doesn't prove another agent won: the push may have reached origin and only
  # the reply been lost. So decide only from what origin holds afterwards.
  pushed=yes
  push_out=$(git push -q --force-with-lease="refs/heads/$ticket:" -u origin "$ticket" 2>&1) || pushed=no
  if ! remote=$(remote_head "$ticket"); then
    die 4 "couldn't reach origin to check the claim. Your local branch $ticket is kept; run: scripts/ticket.sh verify $ticket"
  fi
  if [ "$remote" = "$mine" ]; then
    [ "$pushed" = yes ] || track "$ticket"
    echo "claimed $ticket (claim $id) on branch $ticket"
    return 0
  fi
  abandon
  if [ -z "$remote" ]; then
    printf '%s\n' "$push_out" >&2
    die 4 "the push failed and origin has no branch $ticket, so nobody holds the claim. Try again."
  fi
  die 3 "lost the race for $ticket: another agent created its branch first"
}

# Checks a claim whose outcome wasn't known (exit 4), using the local branch left behind.
verify() {
  ticket=$1
  mine=$(git rev-parse --verify -q "refs/heads/$ticket") || die 2 "there's no local branch $ticket"
  remote=$(remote_head "$ticket") || die 4 "couldn't reach origin"
  if [ "$remote" = "$mine" ]; then
    echo "claimed: origin's $ticket is your claim commit"
    track "$ticket"
  elif [ -z "$remote" ]; then
    die 4 "origin has no branch $ticket, so the claim didn't happen. Delete the local branch (git branch -D $ticket) and claim again."
  else
    die 3 "origin's $ticket is another agent's commit: the ticket isn't yours. Delete the local branch: git branch -D $ticket"
  fi
}

case "${1:-}" in
  list) list ;;
  claim)
    [ $# -ge 2 ] || die 2 "usage: scripts/ticket.sh claim <NNN-slug> [agent-name]"
    claim "$2" "${3:-${TICKET_AGENT:-$(id -un)}}"
    ;;
  verify)
    [ $# -ge 2 ] || die 2 "usage: scripts/ticket.sh verify <NNN-slug>"
    verify "$2"
    ;;
  *) die 2 "usage: scripts/ticket.sh list | claim <NNN-slug> [agent-name] | verify <NNN-slug>" ;;
esac
