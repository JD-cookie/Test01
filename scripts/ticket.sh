#!/bin/sh
# Backlog tickets: list the ready ones, and claim one so no other agent works on it.
#
#   scripts/ticket.sh list
#   scripts/ticket.sh claim <NNN-slug> [agent-name]
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
#   4. Check that the branch on origin points at our commit. Only then is the claim ours.
#
# The ticket list is read from origin/main, not the working tree. Claims are visible as
# branches on origin: a claim reaches main's backlog only when its PR merges.
# Releasing a claim means deleting its branch on origin. Only the user does that.
#
# Exit codes: 0 claimed (or listed), 2 usage or not a ready ticket, 3 already claimed or lost the race.
set -eu

backlog=docs/backlog/README.md

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
  git fetch -q origin main
  branches=$(git ls-remote --heads origin | sed 's|.*refs/heads/||')
  tickets | while read -r slug status; do
    [ "$status" = ready ] || continue
    if printf '%s\n' "$branches" | grep -qx -- "$slug"; then
      echo "$slug  claimed (branch exists on origin)"
    else
      echo "$slug  ready"
    fi
  done
}

claim() {
  ticket=$1
  agent=$2
  printf '%s' "$ticket" | grep -Eqx '[0-9]{3}-[a-z0-9-]+' || die 2 "not a ticket name: $ticket (expected NNN-slug)"
  printf '%s' "$agent" | grep -Eqx '[A-Za-z0-9._@-]+' || die 2 "agent name may only use letters, digits, and . _ @ -"
  if ! git diff --quiet || ! git diff --cached --quiet; then
    die 2 "commit or stash your changes first"
  fi

  git fetch -q origin main
  status=$(tickets | awk -v t="$ticket" '$1 == t { $1 = ""; sub(/^ /, ""); print }')
  [ -n "$status" ] || die 2 "$ticket isn't a numbered ticket in $backlog on origin/main"
  [ "$status" = ready ] || die 2 "$ticket has status '$status' on origin/main, not 'ready'"
  if git ls-remote --exit-code --heads origin "refs/heads/$ticket" >/dev/null; then
    die 3 "$ticket is already claimed: the branch exists on origin"
  fi
  git show-ref --quiet "refs/heads/$ticket" && die 2 "a local branch $ticket exists. Delete it first: git branch -D $ticket"

  id=$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')
  when=$(date -u +%Y-%m-%dT%H:%MZ)
  start=$(git symbolic-ref --quiet --short HEAD || git rev-parse HEAD)
  git switch -q --no-track -c "$ticket" origin/main
  sed -i "/](${ticket}\.md)/s/| ready |/| in progress (claim $id, $agent, $when) |/" "$backlog"
  if git diff --quiet; then
    git switch -q "$start"; git branch -q -D "$ticket"
    die 2 "couldn't find the status cell of $ticket in $backlog"
  fi
  git add "$backlog"
  git commit -q -m "chore(repo): claim ticket $ticket" -m "Claim-Id: $id
Claimed-By: $agent"

  if ! git push -q --force-with-lease="refs/heads/$ticket:" -u origin "$ticket" 2>/dev/null; then
    git switch -q "$start"; git branch -q -D "$ticket"
    die 3 "lost the race for $ticket: another agent created its branch first"
  fi
  remote=$(git ls-remote origin "refs/heads/$ticket" | cut -f1)
  if [ "$remote" != "$(git rev-parse HEAD)" ]; then
    git switch -q "$start"; git branch -q -D "$ticket"
    die 3 "lost the race for $ticket: its branch on origin isn't our claim commit"
  fi
  echo "claimed $ticket (claim $id) on branch $ticket"
}

case "${1:-}" in
  list) list ;;
  claim)
    [ $# -ge 2 ] || die 2 "usage: scripts/ticket.sh claim <NNN-slug> [agent-name]"
    claim "$2" "${3:-${TICKET_AGENT:-$(id -un)}}"
    ;;
  *) die 2 "usage: scripts/ticket.sh list | claim <NNN-slug> [agent-name]" ;;
esac
