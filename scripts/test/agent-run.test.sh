#!/usr/bin/env bash
# Tests for scripts/agent-run.sh and scripts/agent-token.sh: acceptance checks 1 to 6 of
# docs/features/0007-agent-runner.md.
#
#   npm run test:scripts        (or: bash scripts/test/agent-run.test.sh)
#
# Each case runs the real runner against a scratch setup: a local bare repo as origin, holding a
# small backlog with one ready ticket, and stub gh, claude, curl, npm, and bwrap commands first
# on PATH. The stubs record how they were called and answer from files the case writes. No case
# reaches GitHub: GIT_ALLOW_PROTOCOL=file, and the API is the curl and gh stubs.
#
# Prints "ok N" for each acceptance check that passes, "skip N …" for a case that needs a real
# bwrap or a TCP listener when there isn't one (or inside the runner's sandbox,
# AGENT_RUN_IN_SANDBOX=1), and "not ok N …" with the reasons otherwise. Exits 1 if any failed.
set -uo pipefail

repo=$(cd "$(dirname "$0")/../.." && pwd)
runner=$repo/scripts/agent-run.sh
command -v jq >/dev/null || { echo "not ok - the tests need jq"; exit 1; }
[ -d "$repo/node_modules/@commitlint/cli" ] || { echo "not ok - run npm install at the repo root first"; exit 1; }

# Git sets GIT_DIR, GIT_INDEX_FILE, and others while it runs a hook, such as the pre-commit hook
# that runs these tests. Left set, every git command below would act on the repo being committed,
# not on the scratch repos. So clear them all, and check that a fresh folder isn't in a repo.
for v in $(env | sed -n 's/^\(GIT_[A-Z_]*\)=.*/\1/p'); do
  [ "$v" = GIT_EXEC_PATH ] || unset "$v"
done
top=$(mktemp -d)
trap 'rm -rf "$top"' EXIT
if git -C "$top" rev-parse --git-dir >/dev/null 2>&1; then
  echo "not ok - a fresh folder looks like it's inside a git repo; refusing to run"
  exit 1
fi
export GIT_ALLOW_PROTOCOL=file
export GIT_CONFIG_NOSYSTEM=1
unset VALKEY_URL GH_TOKEN GIT_CONFIG_COUNT
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
    [ ! -f "${T:-}/out" ] || { echo "  the last run's output ends:"; tail -n 8 "$T/out" | sed 's/^/    /'; }
    failures=$((failures + 1))
  fi
  problems=()
}
skip() { echo "skip $1 - $2"; }

# A real bwrap that can make a sandbox, outside the runner's own sandbox.
real_bwrap=no
if [ "${AGENT_RUN_IN_SANDBOX:-}" != 1 ] && command -v bwrap >/dev/null &&
  bwrap --ro-bind / / --dev /dev --proc /proc --unshare-net --unshare-pid true 2>/dev/null; then
  real_bwrap=$(command -v bwrap)
fi

FAKE_TOKEN="ghs_$(printf 'A%.0s' $(seq 256)).$(printf 'B%.0s' $(seq 128)).$(printf 'C%.0s' $(seq 130))"
MACHINE_ID=abcdef0123456789abcdef0123456789
AGENT=runner-abcdef012345

# ---- The scratch setup ---------------------------------------------------------------------

# setup [status of ticket 0042]: a fresh scratch folder $T with origin, keys, and stubs.
setup() {
  T=$(mktemp -d "$top/case.XXXX")
  mkdir -p "$T/bin" "$T/calls" "$T/agent" "$T/gh" "$T/config/jd-cookie-agent" "$T/config/gh" "$T/run" "$T/home/.ssh"
  export XDG_DATA_HOME=$T/data XDG_STATE_HOME=$T/state XDG_CONFIG_HOME=$T/config XDG_RUNTIME_DIR=$T/run
  export GH_CONFIG_DIR=$T/config/gh
  export AGENT_RUN_ORIGIN=$T/origin.git AGENT_RUN_GITHUB_API=https://api.test
  export AGENT_RUN_MACHINE_ID_FILE=$T/machine-id
  export AGENT_RUN_AGENT_TIME=60s AGENT_RUN_CHECK_TIME=60s AGENT_RUN_TITLE_TIME=60s AGENT_RUN_KILL_AFTER=2s
  export STUB_T=$T STUB_REPO=$repo
  printf '%s' "$FAKE_TOKEN" >"$T/token"
  echo "$MACHINE_ID" >"$T/machine-id"
  openssl genrsa -out "$T/config/jd-cookie-agent/app.pem" 2048 2>/dev/null
  chmod 600 "$T/config/jd-cookie-agent/app.pem"
  openssl rsa -in "$T/config/jd-cookie-agent/app.pem" -pubout -out "$T/app.pub" 2>/dev/null
  echo "APP_CLIENT_ID=Iv23testclient" >"$T/config/jd-cookie-agent/app.env"
  echo '[]' >"$T/gh/pulls.json"
  # More labels than one page holds, without the runner's two.
  seq 1 120 | jq -R '{name: ("label-" + .)}' | jq -s . >"$T/gh/labels.json"
  echo pass >"$T/check.mode"
  write_stubs
  local seed=$T/seed status=${1:-ready}
  git init -q -b main "$seed"
  mkdir -p "$seed/docs/backlog" "$seed/scripts" "$seed/src" "$seed/.github/workflows" "$seed/server" "$seed/app"
  echo '{"name":"server"}' >"$seed/server/package.json"
  echo '{"name":"app"}' >"$seed/app/package.json"
  cp "$repo/scripts/ticket.sh" "$seed/scripts/"
  cp "$repo/commitlint.config.mjs" "$repo/package.json" "$seed/"
  printf 'node_modules/\n.agent/\n' >"$seed/.gitignore"
  cat >"$seed/docs/backlog/README.md" <<EOF
# Backlog

| # | Item | Area | Status | Notes |
|---|---|---|---|---|
| 0042 | [Do a thing](0042-thing.md) | Server | $status | A test ticket. |
EOF
  echo "# Do a thing" >"$seed/docs/backlog/0042-thing.md"
  echo one >"$seed/src/file.txt"
  printf '\000\001\002binary' >"$seed/src/blob.bin"
  echo "name: CI" >"$seed/.github/workflows/ci.yml"
  git -C "$seed" add -A
  git -C "$seed" -c user.name=t -c user.email=t@example.invalid commit -q -m "chore: seed"
  git clone -q --bare "$seed" "$T/origin.git"
  export PATH="$T/bin:$ORIG_PATH"
}
ORIG_PATH=$PATH

write_stubs() {
  # curl: the token's two API calls. Records the Authorization header and the order of calls.
  cat >"$T/bin/curl" <<'EOF'
#!/usr/bin/env bash
# The whole command line, before it's parsed: the token and the JWT must never be on it.
printf '%s\n' "$*" >>"$STUB_T/calls/curl.args"
method=GET url= headers_in=no
while [ $# -gt 0 ]; do
  case $1 in
    -o) echo "curl stub: -o (writing the answer to a file) isn't expected" >&2; exit 2 ;;
    -w) shift ;;
    -X) method=$2; shift ;;
    -H) [ "$2" = @- ] && headers_in=yes; shift ;;
    --data-binary) shift ;;
    -*) ;;
    *) url=$1 ;;
  esac
  shift
done
[ "$headers_in" = yes ] && grep '^Authorization:' | sed 's/^Authorization: Bearer //' >>"$STUB_T/calls/jwt"
mode=$(cat "$STUB_T/curl.mode" 2>/dev/null || echo ok)
if [ "$mode" = 401 ]; then printf '{"message":"Bad credentials"}\n401'; exit 0; fi
case $url in
  */installation) printf '{"id":77}\n200' ;;
  */access_tokens) echo token >>"$STUB_T/calls/seq"; printf '{"token":"%s"}\n201' "$(cat "$STUB_T/token")" ;;
  *) printf '{}\n404' ;;
esac
EOF
  # gh: only "gh api", against files in $T/gh. --jq goes through jq, like gh's.
  cat >"$T/bin/gh" <<'EOF'
#!/usr/bin/env bash
[ "$1" = api ] || { echo "gh stub: only gh api" >&2; exit 1; }
shift
printf '%s\n' "$*" >>"$STUB_T/calls/gh.args"
printf '%s\n' "${GH_TOKEN:-}" >"$STUB_T/calls/gh.token"
if [ -n "${STUB_CRED:-}" ]; then
  printf 'protocol=https\nhost=github.com\n\n' | git credential fill >"$STUB_T/calls/cred.out" 2>&1
  printf 'protocol=https\nhost=evil.example\n\n' | GIT_TERMINAL_PROMPT=0 git credential fill >"$STUB_T/calls/cred-other.out" 2>&1
fi
method=GET paginate=no jqx= input= path= fields=()
while [ $# -gt 0 ]; do
  case $1 in
    -X) method=$2; shift ;;
    --paginate) paginate=yes ;;
    --jq) jqx=$2; shift ;;
    --input) input=$2; shift ;;
    -f) fields+=("$2"); shift ;;
    *) path=$1 ;;
  esac
  shift
done
G=$STUB_T/gh
answer() { if [ -n "$jqx" ]; then jq -r "$jqx"; else cat; fi; }
case "$method $path" in
  "GET users/jd-cookie-agent[bot]") echo '{"id":358547770,"login":"jd-cookie-agent[bot]"}' | answer ;;
  "GET repos/JD-cookie/Test01/labels?per_page=100")
    if [ "$paginate" = yes ]; then jq '.[0:100]' "$G/labels.json" | answer; jq '.[100:]' "$G/labels.json" | answer
    else jq '.[0:100]' "$G/labels.json" | answer; fi ;;
  "POST repos/JD-cookie/Test01/labels")
    name=$(printf '%s\n' "${fields[@]}" | sed -n 's/^name=//p')
    echo "label $name" >>"$STUB_T/calls/seq"
    jq --arg n "$name" '. + [{name: $n}]' "$G/labels.json" >"$G/l.tmp" && mv "$G/l.tmp" "$G/labels.json"
    echo '{}' | answer ;;
  "GET repos/JD-cookie/Test01/pulls?state=all&head="*)
    head=${path#*head=JD-cookie:}; head=${head%%&*}
    jq --arg h "$head" '[.[] | select(.head.ref == $h)]' "$G/pulls.json" | answer ;;
  "POST repos/JD-cookie/Test01/pulls")
    if [ "$(jq '.body | length' "$input")" -gt 65536 ]; then
      echo "gh: Validation Failed: body is too long (maximum is 65536 characters) (HTTP 422)" >&2; exit 1
    fi
    n=$((100 + $(jq length "$G/pulls.json")))
    cp "$input" "$STUB_T/calls/pr-$n.json"
    echo "pr $n" >>"$STUB_T/calls/seq"
    jq --arg n "$n" --slurpfile r "$input" '. + [{number: ($n|tonumber), state: "open", head: {ref: $r[0].head}}]' \
      "$G/pulls.json" >"$G/p.tmp" && mv "$G/p.tmp" "$G/pulls.json"
    echo "{\"number\":$n}" | answer ;;
  "POST repos/JD-cookie/Test01/issues/"*"/labels")
    n=${path#repos/JD-cookie/Test01/issues/}; n=${n%/labels}
    printf '%s\n' "${fields[@]}" | sed -n 's/^labels\[\]=//p' >"$STUB_T/calls/pr-$n.labels"
    echo '[]' | answer ;;
  *) echo "gh stub: no answer for $method $path" >&2; exit 1 ;;
esac
EOF
  # claude: runs $T/agent/<try> (or $T/agent/default) as the agent's behavior, in the clone.
  cat >"$T/bin/claude" <<'EOF'
#!/usr/bin/env bash
n=$(( $(cat "$STUB_T/calls/claude.count" 2>/dev/null || echo 0) + 1 ))
echo "$n" >"$STUB_T/calls/claude.count"
echo "claude $n" >>"$STUB_T/calls/seq"
printf '%s\n' "$@" >"$STUB_T/calls/claude-$n.args"
env | sort >"$STUB_T/calls/claude-$n.env"
cat >"$STUB_T/calls/claude-$n.prompt"
settings=; prev=
for a in "$@"; do [ "$prev" = --settings ] && settings=$a; prev=$a; done
[ -n "$settings" ] && cp "$settings" "$STUB_T/calls/claude-$n.settings"
b=$STUB_T/agent/$n; [ -f "$b" ] || b=$STUB_T/agent/default
[ -f "$b" ] || exit 0
TRY=$n
. "$b"
EOF
  # npm: ci links the repo's root node_modules into the clone's root; run check passes,
  # fails, or hangs, as $T/check.mode says.
  cat >"$T/bin/npm" <<'EOF'
#!/usr/bin/env bash
case "$1 ${2:-}" in
  "ci "*)
    if [ -e .git ]; then
      src=${STUB_NM:-$STUB_REPO/node_modules}
      mkdir -p node_modules
      for f in "$src"/* "$src"/.bin; do ln -sfn "$f" "node_modules/$(basename "$f")"; done
    fi ;;
  "run check")
    n=$(( $(cat "$STUB_T/calls/check.count" 2>/dev/null || echo 0) + 1 ))
    echo "$n" >"$STUB_T/calls/check.count"
    env | sort >"$STUB_T/calls/check-$n.env"
    mode=$(cat "$STUB_T/check.mode")
    case $mode in
      pass) exit 0 ;;
      fail) echo "check output line $n: FAILED"; exit 1 ;;
      fail-once) [ "$n" -ge 2 ] || { echo "first check fails"; exit 1; } ;;
      hang) [ "$n" -ge 2 ] || { trap '' TERM; while :; do sleep 0.1; done; } ;;
      modify) echo changed >>src/file.txt; exit 0 ;;
      tamper) git config remote.origin.pushurl "$STUB_T/decoy.git"; git config url."$STUB_T/decoy.git".insteadOf "$STUB_T/origin.git"; exit 0 ;;
      big) for i in $(seq 300); do printf 'L%03d %0400d\n' "$i" 0; done; exit 1 ;;
      fences) for i in $(seq 300); do printf '%0399d\n' 0 | tr 0 '`'; done; exit 1 ;;
    esac ;;
  *) ;;
esac
EOF
  # bwrap: records its arguments and environment. Its setup probes answer as a working sandbox
  # would (the masked file can't be read; only lo), unless $T/bwrap.mode is "direct". Then it
  # runs the command after its options, in --chdir's folder. "direct" stands for a bwrap that
# doesn't sandbox: the command runs as it is, and the network is the host's.
  cat >"$T/bin/bwrap" <<'EOF'
#!/usr/bin/env bash
n=$(( $(cat "$STUB_T/calls/bwrap.count" 2>/dev/null || echo 0) + 1 ))
echo "$n" >"$STUB_T/calls/bwrap.count"
printf '%s\n' "$@" >"$STUB_T/calls/bwrap-$n.args"
env | sort >"$STUB_T/calls/bwrap-$n.env"
mode=$(cat "$STUB_T/bwrap.mode" 2>/dev/null || echo sandbox)
last=${*: -1}
if [ "$mode" != direct ]; then
  case $last in
    */agent-run-probe-secret) exit 1 ;;
    /proc/net/dev) printf 'Inter-|   Receive\n face |bytes\n    lo: 0 0 0 0\n'; exit 0 ;;
  esac
elif [ "$last" = /proc/net/dev ]; then
  # Not a sandbox: the host's network, whatever network this test itself runs in.
  printf 'Inter-|   Receive\n face |bytes\n    lo: 0 0 0 0\n  eth0: 0 0 0 0\n'; exit 0
fi
dir=.
while [ $# -gt 0 ]; do
  case $1 in
    --unshare-pid | --unshare-net | --die-with-parent) shift ;;
    --tmpfs | --dev | --proc) shift 2 ;;
    --chdir) dir=$2; shift 2 ;;
    --ro-bind | --bind) shift 3 ;;
    *) break ;;
  esac
done
cd "$dir" && exec "$@"
EOF
  chmod +x "$T/bin/"*
}

# run_runner [args…]: runs the runner, leaves its exit code in $rc and its output in $T/out.
run_runner() {
  rc=0
  (cd "$repo" && timeout 300 "$runner" "$@") >"$T/out" 2>&1 || rc=$?
}

# An agent behavior: commit a change and write pr.md with the title $1.
agent_commit() { # agent_commit <file in $T/agent> <title>
  cat >"$T/agent/$1" <<EOF
echo "change \$TRY" >>src/file.txt
git add -A && git commit -q -m "feat(server): change \$TRY"
printf '%s\n\nTicket: 0042-thing (docs/tickets/0042-thing.md)\nBody of try %s.\n' '$2' "\$TRY" >.agent/pr.md
EOF
}

claude_calls() { cat "$T/calls/claude.count" 2>/dev/null || echo 0; }
check_calls() { cat "$T/calls/check.count" 2>/dev/null || echo 0; }
prs() { ls "$T/calls" | grep -c '^pr-[0-9]*\.json$'; }
pr_json() { cat "$T/calls/pr-$1.json"; }
last_pr() { ls "$T/calls" | sed -n 's/^pr-\([0-9]*\)\.json$/\1/p' | sort -n | tail -n 1; }
origin_has() { git -C "$T/origin.git" rev-parse -q --verify "refs/heads/$1" >/dev/null; }
clone=
run_dir() { ls -d "$T/state/jd-cookie-agent/runs/"* | tail -n 1; }

# restore <run folder> <into>: restores saved work into a fresh clone of origin, as
# "Stopping for help" says.
restore() {
  git clone -q "$T/origin.git" "$2"
  [ "$(cat "$1/base.txt")" = none ] || git -C "$2" checkout -q "$(cat "$1/base.txt")"
  if [ -f "$1/commits.bundle" ]; then
    git -C "$2" fetch -q "$1/commits.bundle" HEAD && git -C "$2" checkout -q FETCH_HEAD
  fi
  [ ! -f "$1/uncommitted.patch" ] || git -C "$2" apply "$1/uncommitted.patch"
}
# Lists a tree's files with their content hashes, without .git, node_modules, and .agent.
tree_of() {
  (cd "$1" && find . -path ./.git -prune -o -path ./node_modules -prune -o -path ./.agent -prune -o -type f -print |
    sort | while read -r f; do printf '%s %s\n' "$(git hash-object "$f")" "$f"; done)
}

# Makes a claim branch on origin for 0042-thing, with the trailer Claimed-By: $1.
claim_branch() { # claim_branch <agent> [branch]
  local b=${2:-0042-thing} w=$T/claimer
  rm -rf "$w"
  git clone -q "$T/origin.git" "$w"
  git -C "$w" switch -q -c "$b"
  echo "claim" >>"$w/docs/backlog/README.md"
  git -C "$w" -c user.name=x -c user.email=x@example.invalid commit -q -am "chore(repo): claim ticket $b" -m "Claim-Id: 1234abcd
Claimed-By: $1"
  git -C "$w" push -q origin "$b"
}

# ---- 1. No ticket --------------------------------------------------------------------------

setup designed
run_runner
expect "exit 0 (was $rc)" [ "$rc" -eq 0 ]
expect "logs 'no ready ticket'" grep -q 'no ready ticket' "$T/out"
expect "claude called 0 times" [ "$(claude_calls)" -eq 0 ]
expect "no claim branch on origin" bash -c "! git -C '$T/origin.git' rev-parse -q --verify refs/heads/0042-thing"
result 1 "no ticket: no claim, no claude call"

# ---- 2. Build ------------------------------------------------------------------------------

setup
agent_commit default 'feat(server): do a thing'
run_runner
clone=$XDG_DATA_HOME/jd-cookie-agent/repo
expect "exit 0 (was $rc): $(tail -n 3 "$T/out" | tr '\n' ' ')" [ "$rc" -eq 0 ]
expect "the claim branch is on origin" origin_has 0042-thing
expect "claude called once" [ "$(claude_calls)" -eq 1 ]
expect "claude got the build prompt" grep -q 'building ticket 0042-thing' "$T/calls/claude-1.prompt"
expect "the check stub ran once" [ "$(check_calls)" -eq 1 ]
expect "origin's branch has the agent's commit" bash -c "git -C '$T/origin.git' log --format=%s 0042-thing | grep -q 'change 1'"
n=$(last_pr)
expect "one PR opened" [ "$(prs)" -eq 1 ]
expect "the PR's title is pr.md's" [ "$(pr_json "$n" | jq -r .title)" = 'feat(server): do a thing' ]
expect "the PR isn't a draft" [ "$(pr_json "$n" | jq -r .draft)" = false ]
expect "the PR's body is the rest of pr.md" bash -c "jq -r .body '$T/calls/pr-$n.json' | grep -q 'Body of try 1'"
expect "the PR has the label agent-run only" [ "$(cat "$T/calls/pr-$n.labels")" = agent-run ]
expect "the label agent-run was created first" bash -c "grep -n '' '$T/calls/seq' | grep -q 'label agent-run' && [ \$(grep -n 'label agent-run' '$T/calls/seq' | cut -d: -f1) -lt \$(grep -n '^pr ' '$T/calls/seq' | cut -d: -f1) ]"
expect "needs-help wasn't created" bash -c "! grep -q 'label needs-help' '$T/calls/seq'"
expect "the claim commit is the App's" [ "$(git -C "$T/origin.git" log --format='%an <%ae>|%cn' 0042-thing~1 -1)" = 'jd-cookie-agent[bot] <358547770+jd-cookie-agent[bot]@users.noreply.github.com>|jd-cookie-agent[bot]' ]
expect "the agent's commit is the App's" [ "$(git -C "$T/origin.git" log --format=%an 0042-thing -1)" = 'jd-cookie-agent[bot]' ]
# Labels already there (on the second page) aren't created again.
setup
agent_commit default 'feat(server): do a thing'
jq '. + [{name: "agent-run"}, {name: "needs-help"}]' "$T/gh/labels.json" >"$T/gh/l" && mv "$T/gh/l" "$T/gh/labels.json"
run_runner
expect "an existing label on page 2 isn't created again" bash -c "! grep -q '^label ' '$T/calls/seq'"
result 2 "build: claim, one agent run, checks, push, PR with agent-run"

# ---- 3. Check retries ----------------------------------------------------------------------

# Always failing, with a commit, an untracked file, and a changed binary file: 3 tries, then
# a draft PR with needs-help, and the saved work restores exactly.
for variant in pushed refused; do
  setup
  echo fail >"$T/check.mode"
  if [ "$variant" = refused ]; then
    # origin refuses a push that changes a workflow, as GitHub does for an App without Workflows.
    cat >"$T/origin.git/hooks/pre-receive" <<'EOF'
#!/bin/sh
while read -r old new ref; do
  if git diff --name-only refs/heads/main "$new" | grep -q '^.github/workflows/'; then
    echo "refusing to allow a GitHub App to create or update workflow \`.github/workflows/ci.yml\` without \`workflows\` permission" >&2
    exit 1
  fi
done
EOF
    chmod +x "$T/origin.git/hooks/pre-receive"
  fi
  cat >"$T/agent/default" <<EOF
if [ "\$TRY" = 1 ]; then
  echo committed >>src/file.txt
  [ "$variant" = refused ] && echo "on: push" >>.github/workflows/ci.yml
  git add -A && git commit -q -m "feat(server): change"
fi
if [ "\$TRY" = 3 ]; then
  echo untracked >src/new.txt
  printf '\003\004' >>src/blob.bin
fi
printf 'feat(server): do a thing\n\nbody\n' >.agent/pr.md
EOF
  run_runner
  clone=$XDG_DATA_HOME/jd-cookie-agent/repo
  n=$(last_pr); r=$(run_dir)
  expect "[$variant] exit 0 (was $rc)" [ "$rc" -eq 0 ]
  expect "[$variant] claude called 3 times" [ "$(claude_calls)" -eq 3 ]
  expect "[$variant] one draft PR" [ "$(pr_json "$n" | jq -r .draft)" = true ]
  expect "[$variant] labels agent-run and needs-help" [ "$(tr '\n' ' ' <"$T/calls/pr-$n.labels")" = "agent-run needs-help " ]
  expect "[$variant] reason in the description" bash -c "jq -r .body '$T/calls/pr-$n.json' | grep -q 'The checks still fail after 3 tries.'"
  for f in base.txt commits.bundle uncommitted.patch; do expect "[$variant] $f saved" [ -f "$r/$f" ]; done
  restore "$r" "$T/restored"
  expect "[$variant] restoring gives the clone's tree" [ "$(tree_of "$T/restored")" = "$(tree_of "$clone")" ]
  expect "[$variant] the description names the saved files" bash -c "jq -r .body '$T/calls/pr-$n.json' | grep -q 'commits.bundle'"
  if [ "$variant" = pushed ]; then
    expect "[pushed] the commit was pushed" bash -c "git -C '$T/origin.git' log --format=%s 0042-thing | grep -q 'feat(server): change'"
  else
    expect "[refused] origin's branch is only the claim" [ "$(git -C "$T/origin.git" rev-list --count main..0042-thing)" -eq 1 ]
    expect "[refused] the description says the push was refused" bash -c "jq -r .body '$T/calls/pr-$n.json' | grep -qi 'refused'"
  fi
done

# A merge commit survives the save.
setup
echo fail >"$T/check.mode"
cat >"$T/agent/1" <<'EOF'
git switch -q -c side && echo side >src/side.txt && git add -A && git commit -q -m "feat(server): side"
git switch -q - && echo main >>src/file.txt && git commit -q -am "feat(server): main side"
git merge -q --no-ff -m "chore: merge side" side && git branch -q -D side
printf 'feat(server): do a thing\n' >.agent/pr.md
EOF
run_runner
restore "$(run_dir)" "$T/restored"
expect "the restored history has the merge" [ "$(git -C "$T/restored" rev-list --merges --count HEAD)" -eq 1 ]

# stop.md with no changes: only base.txt, which restores the base.
setup
echo 'The design doc is wrong about X.' >"$T/stop.md"
echo "cp '$T/stop.md' .agent/stop.md" >"$T/agent/default"
run_runner
r=$(run_dir)
expect "stop.md: only base.txt saved" [ "$(ls "$r" | grep -cE '^(base.txt|commits.bundle|uncommitted.patch)$')" -eq 1 ]
restore "$r" "$T/restored"
expect "stop.md: restoring gives the base" [ "$(git -C "$T/restored" rev-parse HEAD)" = "$(git -C "$T/origin.git" rev-parse 0042-thing)" ]
n=$(last_pr)
expect "stop.md: one draft PR with needs-help" [ "$(pr_json "$n" | jq -r .draft)/$(tr '\n' ' ' <"$T/calls/pr-$n.labels")" = "true/agent-run needs-help " ]
expect "stop.md: its text is in the description" bash -c "jq -r .body '$T/calls/pr-$n.json' | grep -q 'The design doc is wrong about X.'"
expect "stop.md: no comment posted" bash -c "! grep -q 'comments' '$T/calls/gh.args'"
expect "stop.md: one PR call" [ "$(prs)" -eq 1 ]

# An agent that ignores SIGTERM is killed at the kill time, and the next try runs.
setup
export AGENT_RUN_AGENT_TIME=2s AGENT_RUN_KILL_AFTER=1s
echo "trap '' TERM; while :; do sleep 0.1; done" >"$T/agent/1"
agent_commit 2 'feat(server): do a thing'
start=$(date +%s); run_runner; took=$(( $(date +%s) - start ))
expect "SIGTERM ignored: try 1 ended at the kill time (run took ${took}s)" [ "$took" -lt 30 ]
expect "SIGTERM ignored: try 2 ran and the PR opened" [ "$(claude_calls)/$(prs)" = "2/1" ]

# A check that changes a tracked file and passes: a failed try.
setup
echo modify >"$T/check.mode"
agent_commit default 'feat(server): do a thing'
run_runner
expect "a check that changes a file fails the try" [ "$(claude_calls)" -eq 3 ]
expect "the fix prompt says the checks changed the clone" grep -q "The checks changed the clone" "$T/calls/claude-2.prompt"

# 70,000 characters of stop.md: the description stays under 60,000 and starts with the reason.
setup
head -c 70000 /dev/zero | tr '\0' 'x' >"$T/stop.md"
echo "cp '$T/stop.md' .agent/stop.md" >"$T/agent/default"
run_runner
n=$(last_pr); len=$(pr_json "$n" | jq -r '.body | length')
expect "a long stop.md: description under 60,000 ($len)" [ "$len" -lt 60000 ]
expect "a long stop.md: it starts with the reason and the run folder" bash -c "jq -r .body '$T/calls/pr-$n.json' | head -n 3 | grep -q xxxxx && jq -r .body '$T/calls/pr-$n.json' | grep -q 'Run folder:'"
# … and 70,000-plus characters of output and of pr.md's body.
setup
echo big >"$T/check.mode"
cat >"$T/agent/default" <<'EOF'
echo x >>src/file.txt && git commit -q -am "feat(server): x"
{ echo 'feat(server): do a thing'; echo; head -c 70000 /dev/zero | tr '\0' 'y'; } >.agent/pr.md
EOF
run_runner
n=$(last_pr); len=$(pr_json "$n" | jq -r '.body | length')
expect "long output and body: description under 60,000 ($len)" [ "$len" -lt 60000 ]
expect "long output and body: starts with the reason" bash -c "jq -r .body '$T/calls/pr-$n.json' | head -n 3 | grep -q 'The checks still fail'"
expect "long output and body: keeps the output's end" bash -c "jq -r .body '$T/calls/pr-$n.json' | grep -q '^L300 '"

# Output full of ``` fences: the description is escaped before it's cut, and still fits.
setup
echo fail >"$T/check.mode"
echo fences >"$T/check.mode"
agent_commit default 'feat(server): do a thing'
run_runner
n=$(last_pr)
expect "output full of fences: a draft PR opened (exit $rc)" [ "$(pr_json "$n" | jq -r .draft 2>/dev/null)" = true ]
expect "output full of fences: under 60,000 ($(pr_json "$n" | jq -r '.body | length' 2>/dev/null))" [ "$(pr_json "$n" | jq -r '.body | length')" -lt 60000 ]
expect "output full of fences: only the two fences around the output are left" [ "$(pr_json "$n" | jq -r .body | grep -o '```' | wc -l)" -eq 2 ]

# A hanging check fails after its time limit, and the next try runs.
setup
echo hang >"$T/check.mode"
export AGENT_RUN_CHECK_TIME=2s AGENT_RUN_KILL_AFTER=1s
agent_commit default 'feat(server): do a thing'
run_runner
expect "a hanging check: try 2 ran, and the PR opened after it" [ "$(claude_calls)/$(check_calls)/$(prs)" = "2/2/1" ]
expect "a hanging check: the fix prompt says it ran out of time" grep -q 'ran out of time' "$T/calls/claude-2.prompt"

# Failing once, then passing: a normal PR after 2 tries.
setup
echo fail-once >"$T/check.mode"
agent_commit default 'feat(server): do a thing'
run_runner
n=$(last_pr)
expect "fail once: 2 tries, a normal PR" [ "$(claude_calls)/$(pr_json "$n" | jq -r .draft)" = "2/false" ]

# A title commitlint rejects counts as a failed check, and is never a PR's title.
setup
agent_commit default 'Bad title'
run_runner
expect "a bad title: 3 tries" [ "$(claude_calls)" -eq 3 ]
expect "a bad title: no PR has it" bash -c "! jq -r .title '$T'/calls/pr-*.json | grep -qx 'Bad title'"
n=$(last_pr)
expect "a bad title: the draft gets the fallback title" [ "$(pr_json "$n" | jq -r .title)" = 'chore(repo): build ticket 0042-thing' ]
expect "a bad title: the fix prompt has commitlint's output" grep -q 'subject' "$T/calls/claude-2.prompt"

# A good title, but no Ticket line in the body: a failed try, and the fix prompt says so.
setup
printf 'echo x >>src/file.txt && git commit -q -am "feat(server): x"\nprintf "feat(server): do a thing\\n\\nNo ticket line here.\\n" >.agent/pr.md\n' >"$T/agent/1"
agent_commit 2 'feat(server): do a thing'
run_runner
expect "no Ticket line: try 1 failed, try 2 opened the PR" [ "$(claude_calls)/$(prs)" = "2/1" ]
expect "no Ticket line: the fix prompt says so" grep -q 'must start with the line: Ticket: 0042-thing' "$T/calls/claude-2.prompt"
# A Ticket line inside another line, or with another path: failed tries too.
for bad in 'Note: Ticket: 0042-thing (docs/tickets/0042-thing.md)' 'Ticket: 0042-thing (wrong-path)'; do
  setup
  printf 'echo x >>src/file.txt && git commit -q -am "feat(server): x"\nprintf "feat(server): do a thing\\n\\n%s\\n" >.agent/pr.md\n' "$bad" >"$T/agent/1"
  agent_commit 2 'feat(server): do a thing'
  run_runner
  expect "Ticket line '$bad': try 1 failed, try 2 opened the PR" [ "$(claude_calls)/$(prs)" = "2/1" ]
done
# A valid Ticket line and a long body: 58,000 characters, under the limit, but 115,000 bytes,
# more than a pipe holds. The PR opens after one try.
setup
cat >"$T/agent/default" <<'EOF'
echo x >>src/file.txt && git commit -q -am "feat(server): x"
line=$(printf 'é%.0s' $(seq 99))
{ printf 'feat(server): do a thing\n\nTicket: 0042-thing (docs/tickets/0042-thing.md)\n'; for i in $(seq 580); do printf '%s\n' "$line"; done; } >.agent/pr.md
EOF
run_runner
expect "a long valid body: one try, a normal PR" [ "$(claude_calls)/$(prs)/$(pr_json "$(last_pr)" | jq -r .draft)" = "1/1/false" ]
expect "a long valid body: more than 64 KiB" [ "$(wc -c <"$XDG_DATA_HOME/jd-cookie-agent/repo/.agent/pr.md")" -gt 65536 ]
# A body over the limit: a failed try, and the fix prompt says so.
setup
cat >"$T/agent/1" <<'EOF'
echo x >>src/file.txt && git commit -q -am "feat(server): x"
{ printf 'feat(server): do a thing\n\nTicket: 0042-thing (docs/tickets/0042-thing.md)\n'; head -c 70000 /dev/zero | tr '\0' 'z'; echo; } >.agent/pr.md
EOF
agent_commit 2 'feat(server): do a thing'
run_runner
expect "a body over the limit: try 1 failed, try 2 opened the PR" [ "$(claude_calls)/$(prs)" = "2/1" ]
expect "a body over the limit: the fix prompt says so" grep -q 'keep it under 60000' "$T/calls/claude-2.prompt"

# The agent's own commitlint config doesn't count: main's does, and the agent's isn't loaded.
setup
cat >"$T/agent/default" <<EOF
cat >commitlint.config.mjs <<'CFG'
import { writeFileSync } from 'node:fs';
writeFileSync('$T/pwned', 'loaded');
export default { rules: {} };
CFG
git add -A && git commit -q -m "chore(repo): loosen commitlint"
printf 'feat(nope): a scope main rejects\n' >.agent/pr.md
EOF
run_runner
expect "the agent's commitlint config: the title still fails" [ "$(claude_calls)" -eq 3 ]
expect "the agent's commitlint config isn't loaded" [ ! -e "$T/pwned" ]

# A hanging commitlint fails the title check after its time limit.
setup
mkdir -p "$T/nm/.bin"
for f in "$repo/node_modules"/*; do ln -s "$f" "$T/nm/$(basename "$f")"; done
printf '#!/bin/sh\nsleep 60\n' >"$T/nm/.bin/commitlint"
chmod +x "$T/nm/.bin/commitlint"
export STUB_NM=$T/nm AGENT_RUN_TITLE_TIME=2s AGENT_RUN_KILL_AFTER=1s
agent_commit default 'feat(server): do a thing'
start=$(date +%s); run_runner; took=$(( $(date +%s) - start ))
unset STUB_NM
expect "a hanging commitlint: the title check fails (3 tries)" [ "$(claude_calls)" -eq 3 ]
expect "a hanging commitlint: it ends at the limit (took ${took}s)" [ "$took" -lt 60 ]

# An uncommitted change fails the try before npm run check, and the fix prompt lists it.
setup
cat >"$T/agent/1" <<'EOF'
echo loose >src/loose.txt
printf 'feat(server): do a thing\n' >.agent/pr.md
EOF
agent_commit 2 'feat(server): do a thing'
run_runner
expect "an uncommitted change: the check didn't run on try 1" [ "$(check_calls)" -eq 1 ]
expect "an uncommitted change: the fix prompt lists it" grep -q 'src/loose.txt' "$T/calls/claude-2.prompt"

# A push refused for a workflow change: a draft PR from the branch as it is on origin.
setup
cat >"$T/origin.git/hooks/pre-receive" <<'EOF'
#!/bin/sh
while read -r old new ref; do
  if git diff --name-only refs/heads/main "$new" | grep -q '^.github/workflows/'; then
    echo "refusing to allow a GitHub App to create or update workflow without workflows permission" >&2; exit 1
  fi
done
EOF
chmod +x "$T/origin.git/hooks/pre-receive"
cat >"$T/agent/default" <<'EOF'
echo "on: push" >>.github/workflows/ci.yml && git commit -q -am "ci: change a workflow"
printf 'ci: change a workflow\n\nTicket: 0042-thing (docs/tickets/0042-thing.md)\n' >.agent/pr.md
EOF
run_runner
n=$(last_pr)
expect "a refused push: a draft PR with needs-help" [ "$(pr_json "$n" | jq -r .draft)/$(tr '\n' ' ' <"$T/calls/pr-$n.labels")" = "true/agent-run needs-help " ]
expect "a refused push: the reason is the workflow" bash -c "jq -r .body '$T/calls/pr-$n.json' | grep -q \"changes a workflow, which the runner's App can't push\""
expect "a refused push: origin has only the claim" [ "$(git -C "$T/origin.git" rev-list --count main..0042-thing)" -eq 1 ]
expect "a refused push: the description names the saved files" bash -c "jq -r .body '$T/calls/pr-$n.json' | grep -q 'commits.bundle'"

# Claude's usage limit, in try 1: one claude call, no check, a draft PR with the limit's line.
limit_agent() { printf "echo 'working…'\necho 'Claude AI usage limit reached. Your limit resets 5pm (UTC).'\nexit %s\n" "$1"; }
setup
limit_agent 1 >"$T/agent/default"
run_runner
n=$(last_pr)
expect "usage limit in try 1: one claude call, no check" [ "$(claude_calls)/$(check_calls)" = "1/0" ]
expect "usage limit in try 1: a draft PR with needs-help" [ "$(pr_json "$n" | jq -r .draft)/$(tr '\n' ' ' <"$T/calls/pr-$n.labels")" = "true/agent-run needs-help " ]
expect "usage limit: the description starts with the reason and the line" bash -c "jq -r .body '$T/calls/pr-$n.json' | sed -n '3,4p' | tr '\n' ' ' | grep -q \"Claude's usage limit was reached during try 1 of 3: Claude AI usage limit reached. Your limit resets 5pm\""
# … in try 2, after a failed check.
setup
echo fail >"$T/check.mode"
agent_commit 1 'feat(server): do a thing'
limit_agent 1 >"$T/agent/2"
run_runner
expect "usage limit in try 2: stops after 2 claude calls" [ "$(claude_calls)" -eq 2 ]
expect "usage limit in try 2: the reason says try 2" bash -c "jq -r .body '$T/calls/pr-$(last_pr).json' | grep -q 'during try 2 of 3'"
# The same line with exit 0, or exit 1 with no matching line: ordinary failed tries.
setup
limit_agent 0 >"$T/agent/default"
run_runner
expect "the limit's line with exit 0: an ordinary failed try (3 tries)" [ "$(claude_calls)" -eq 3 ]
setup
printf "echo 'something else went wrong'\nexit 1\n" >"$T/agent/default"
run_runner
expect "exit 1 with no limit line: an ordinary failed try (3 tries)" [ "$(claude_calls)" -eq 3 ]

# A pr.md left over from an earlier try doesn't count: the agent must write it each time.
setup
echo fail-once >"$T/check.mode"
agent_commit 1 'feat(server): first title'
echo ':' >"$T/agent/2"
agent_commit 3 'feat(server): third title'
run_runner
expect "a left-over pr.md: try 2 wrote nothing and failed" [ "$(claude_calls)" -eq 3 ]
expect "a left-over pr.md: the fix prompt says pr.md is missing" grep -q "didn't write .agent/pr.md" "$T/calls/claude-3.prompt"
# The fix try's pr.md wins, and the fix prompt had the build try's.
setup
echo fail-once >"$T/check.mode"
agent_commit 1 'feat(server): build title'
agent_commit 2 'feat(server): fix title'
run_runner
expect "the PR has the fix try's title" [ "$(pr_json "$(last_pr)" | jq -r .title)" = 'feat(server): fix title' ]
expect "the fix prompt held the build try's pr.md" grep -q 'feat(server): build title' "$T/calls/claude-2.prompt"
result 3 "check retries, saved work, stops, the usage limit, and the agent's files"

# ---- 4. Crash, lock, and open PRs ----------------------------------------------------------

# A claim branch with no PR: a draft PR with needs-help, no claude call.
setup
claim_branch "$AGENT"
run_runner
n=$(last_pr)
expect "no PR: a draft PR with needs-help" [ "$(pr_json "$n" | jq -r .draft)/$(tr '\n' ' ' <"$T/calls/pr-$n.labels")" = "true/agent-run needs-help " ]
expect "no PR: the reason" bash -c "jq -r .body '$T/calls/pr-$n.json' | grep -q 'A run stopped while building this ticket'"
expect "no PR: no claude call" [ "$(claude_calls)" -eq 0 ]
expect "no PR: the agent name is runner- and 12 characters of the machine id" grep -q "agent name: $AGENT" "$T/out"
# Merged and closed PRs: skipped, and the run goes on to the list.
setup designed
claim_branch "$AGENT" 0042-thing
claim_branch "$AGENT" 0043-other
echo '[{"number":5,"state":"closed","merged_at":"2026-11-01T00:00:00Z","head":{"ref":"0042-thing"}},{"number":6,"state":"closed","merged_at":null,"head":{"ref":"0043-other"}}]' >"$T/gh/pulls.json"
run_runner
expect "merged and closed: no PR, no claude call" [ "$(prs)/$(claude_calls)" = "0/0" ]
expect "merged and closed: the run goes on to the list" grep -q 'no ready ticket' "$T/out"
# Another agent's claim is never touched.
setup
claim_branch someone-else
before=$(git -C "$T/origin.git" rev-parse 0042-thing)
run_runner
expect "another agent's claim: no PR, no claude call" [ "$(prs)/$(claude_calls)" = "0/0" ]
expect "another agent's claim: its branch is unchanged" [ "$(git -C "$T/origin.git" rev-parse 0042-thing)" = "$before" ]
expect "another agent's claim: its PRs aren't looked up" bash -c "! grep -q 'head=JD-cookie:0042-thing' '$T/calls/gh.args'"
# A second run while the first holds the lock exits 0 at once.
setup
(flock "$XDG_RUNTIME_DIR/jd-cookie-agent.lock" sleep 10) &
holder=$!
sleep 0.5
start=$(date +%s); run_runner; took=$(( $(date +%s) - start ))
kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
expect "the lock: exit 0 at once (${took}s)" [ "$rc/$((took < 5))" = "0/1" ]
expect "the lock: says so" grep -q 'another run holds the lock' "$T/out"
expect "the lock: no claude call" [ "$(claude_calls)" -eq 0 ]
# An open PR, with or without needs-help: nothing happens.
for labels in '[{"name":"agent-run"}]' '[{"name":"agent-run"},{"name":"needs-help"}]'; do
  setup
  claim_branch "$AGENT"
  echo "[{\"number\":9,\"state\":\"open\",\"labels\":$labels,\"head\":{\"ref\":\"0042-thing\"}}]" >"$T/gh/pulls.json"
  before=$(git -C "$T/origin.git" for-each-ref)
  run_runner
  expect "an open PR ($labels): logs PR #9 is open" grep -q 'PR #9 is open' "$T/out"
  expect "an open PR ($labels): no claude call, no PR, no comment" [ "$(claude_calls)/$(prs)/$(grep -c comments "$T/calls/gh.args")" = "0/0/0" ]
  expect "an open PR ($labels): no new claim" [ "$(git -C "$T/origin.git" for-each-ref)" = "$before" ]
  expect "an open PR ($labels): its labels are left alone" [ ! -e "$T/calls/pr-9.labels" ]
done
# An open PR whose labels call failed (no labels): they're added back, needs-help only for a stop.
for kind in stop build; do
  setup
  claim_branch "$AGENT"
  body='Ticket: 0042-thing'; want='agent-run'
  if [ "$kind" = stop ]; then body='**The runner stopped for help.**\n\nThe checks still fail after 3 tries.'; want='agent-run needs-help'; fi
  printf '[{"number":9,"state":"open","labels":[],"body":"%s","head":{"ref":"0042-thing"}}]\n' "$body" >"$T/gh/pulls.json"
  run_runner
  expect "an open $kind PR with no labels: they're added back ($want)" [ "$(tr '\n' ' ' <"$T/calls/pr-9.labels" 2>/dev/null)" = "$want " ]
  expect "an open $kind PR with no labels: no claude call, no new PR" [ "$(claude_calls)/$(prs)" = "0/0" ]
done
# A claim with no PR, whose branch on origin moved on while the clone stayed behind with an
# uncommitted change: the saved work still restores the clone's tree.
setup
claim_branch "$AGENT"
mkdir -p "$XDG_DATA_HOME/jd-cookie-agent"
git clone -q "$T/origin.git" "$XDG_DATA_HOME/jd-cookie-agent/repo"
clone=$XDG_DATA_HOME/jd-cookie-agent/repo
git -C "$clone" switch -q 0042-thing
echo "work in progress" >>"$clone/src/file.txt"
echo "someone else" >"$T/claimer/src/other.txt"
git -C "$T/claimer" add -A
git -C "$T/claimer" -c user.name=x -c user.email=x@example.invalid commit -q -m "chore: move on"
git -C "$T/claimer" push -q origin 0042-thing
run_runner
r=$(run_dir)
expect "a branch that moved on: a draft PR with needs-help" [ "$(tr '\n' ' ' <"$T/calls/pr-$(last_pr).labels")" = "agent-run needs-help " ]
restore "$r" "$T/restored"
expect "a branch that moved on: restoring gives the clone's tree" [ "$(tree_of "$T/restored")" = "$(tree_of "$clone")" ]
# A claim with no PR, whose local branch shares no commit with origin (its history rewritten):
# the work is still saved, with base.txt "none" and the whole history in the bundle.
setup
claim_branch "$AGENT"
mkdir -p "$XDG_DATA_HOME/jd-cookie-agent"
git clone -q "$T/origin.git" "$XDG_DATA_HOME/jd-cookie-agent/repo"
clone=$XDG_DATA_HOME/jd-cookie-agent/repo
git -C "$clone" switch -q --orphan 0042-thing
mkdir -p "$clone/src"
echo "rewritten" >"$clone/src/file.txt"
git -C "$clone" add -A
git -C "$clone" -c user.name=x -c user.email=x@example.invalid commit -q -m "chore: unrelated history"
echo "uncommitted" >>"$clone/src/file.txt"
run_runner
r=$(run_dir)
expect "unrelated histories: a draft PR with needs-help (exit $rc)" [ "$(tr '\n' ' ' <"$T/calls/pr-$(last_pr).labels" 2>/dev/null)" = "agent-run needs-help " ]
expect "unrelated histories: base.txt says none" [ "$(cat "$r/base.txt" 2>/dev/null)" = none ]
restore "$r" "$T/restored"
expect "unrelated histories: restoring gives the clone's tree" [ "$(tree_of "$T/restored")" = "$(tree_of "$clone")" ]
# A hook an earlier ticket's agent left in .husky/_, which husky's own .gitignore ignores, doesn't
# run on the next ticket's claim push.
setup
mkdir -p "$XDG_DATA_HOME/jd-cookie-agent"
git clone -q "$T/origin.git" "$XDG_DATA_HOME/jd-cookie-agent/repo"
mkdir -p "$XDG_DATA_HOME/jd-cookie-agent/repo/.husky/_"
echo '*' >"$XDG_DATA_HOME/jd-cookie-agent/repo/.husky/_/.gitignore"
printf '#!/bin/sh\ntouch "%s/old-hook-ran"\n' "$T" >"$XDG_DATA_HOME/jd-cookie-agent/repo/.husky/_/pre-push"
chmod +x "$XDG_DATA_HOME/jd-cookie-agent/repo/.husky/_/pre-push"
agent_commit default 'feat(server): do a thing'
run_runner
expect "an old ignored hook: the run opened its PR" [ "$(prs)" -eq 1 ]
expect "an old ignored hook: it didn't run on the claim's push" [ ! -e "$T/old-hook-ran" ]
# A withdrawn ticket (claim exit 5) before any agent run: the draft doesn't reuse an old pr.md.
setup
w=$T/fakeseed
git clone -q "$T/origin.git" "$w"
printf '#!/bin/sh\ncase $1 in\n  list) echo "0042-thing  ready" ;;\n  claim) git switch -q -c 0042-thing && echo "ticket: the claim is yours, but on main 0042-thing is now designed, not ready." >&2 && exit 5 ;;\nesac\n' >"$w/scripts/ticket.sh"
git -C "$w" -c user.name=x -c user.email=x@example.invalid commit -q -am "test: a ticket.sh that exits 5"
git -C "$w" push -q origin main
mkdir -p "$XDG_DATA_HOME/jd-cookie-agent"
git clone -q "$T/origin.git" "$XDG_DATA_HOME/jd-cookie-agent/repo"
mkdir -p "$XDG_DATA_HOME/jd-cookie-agent/repo/.agent"
printf 'feat(server): an old ticket\n\nTicket: 0041-old\n' >"$XDG_DATA_HOME/jd-cookie-agent/repo/.agent/pr.md"
run_runner
n=$(last_pr)
expect "a withdrawn ticket: a draft PR with the fallback title" [ "$(pr_json "$n" | jq -r .title)" = 'chore(repo): build ticket 0042-thing' ]
expect "a withdrawn ticket: the old pr.md isn't in it" bash -c "! jq -r .body '$T/calls/pr-$n.json' | grep -q '0041-old'"
expect "a withdrawn ticket: the reason is the claim's message" bash -c "jq -r .body '$T/calls/pr-$n.json' | grep -q 'now designed, not ready'"
result 4 "crash, lock, and open PRs"

# ---- 5. The token --------------------------------------------------------------------------

setup
agent_commit default 'feat(server): do a thing'
# A credential helper in the user's own git config, which must never be asked or told.
git config --file "$T/gitconfig" credential.helper "!f() { echo \"\$1\" >>'$T/user-helper-calls'; echo username=user; echo password=USERS-PAT; }; f"
export STUB_CRED=1 GIT_CONFIG_GLOBAL=$T/gitconfig
run_runner
unset STUB_CRED GIT_CONFIG_GLOBAL
clone=$XDG_DATA_HOME/jd-cookie-agent/repo
jwt=$(head -n 1 "$T/calls/jwt")
IFS=. read -r jh jp js <<<"$jwt"
b64d() { local s=$1; s=$(printf '%s' "$s" | tr '_-' '/+'); while [ $(( ${#s} % 4 )) -ne 0 ]; do s="$s="; done; printf '%s' "$s" | openssl base64 -d -A; }
b64d "$js" >"$T/sig.bin"
expect "the JWT verifies with the key's public half" bash -c "printf '%s.%s' '$jh' '$jp' | openssl dgst -sha256 -verify '$T/app.pub' -signature '$T/sig.bin'"
payload=$(b64d "$jp")
expect "the JWT's iss is the client id" [ "$(printf '%s' "$payload" | jq -r .iss)" = Iv23testclient ]
expect "the JWT lasts 600 seconds" [ "$(printf '%s' "$payload" | jq '.exp - .iat')" -eq 600 ]
expect "the JWT's header" [ "$(b64d "$jh")" = '{"alg":"RS256","typ":"JWT"}' ]
expect "the 520-character token reaches gh as GH_TOKEN" [ "$(cat "$T/calls/gh.token")" = "$FAKE_TOKEN" ]
expect "the fake token has 520 characters" [ "${#FAKE_TOKEN}" -eq 520 ]
expect "the credential helper answers with the token" bash -c "grep -qx 'username=x-access-token' '$T/calls/cred.out' && grep -qxF 'password=$FAKE_TOKEN' '$T/calls/cred.out'"
expect "the user's own credential helper is never asked or told" [ ! -e "$T/user-helper-calls" ]
expect "curl never writes an answer to a file" bash -c "! grep -qE '(^| )-o( |$)' '$T/calls/curl.args'"
expect "the credential helper gives nothing for another host" bash -c "! grep -q '^password=' '$T/calls/cred-other.out'"
expect "the clone's .git/config has no credential.helper" bash -c "! grep -q credential '$clone/.git/config'"
# A new token after the agent's run, before the push and the PR.
expect "a new token after the agent ran, before the PR" bash -c "awk '/^claude/ { c = NR } /^token/ && c { t = NR } /^pr / { p = NR } END { exit !(c && t > c && p > t) }' '$T/calls/seq'"
expect "the token isn't in any log or run file" bash -c "! grep -rqF '$FAKE_TOKEN' '$T/state'"
expect "the token isn't on any recorded command line" bash -c "! cat '$T/calls/'*.args | grep -qF '$FAKE_TOKEN'"
expect "the token isn't in claude's environment" bash -c "! grep -q '^GH_TOKEN=' '$T/calls/claude-1.env' && ! grep -qF '$FAKE_TOKEN' '$T/calls/claude-1.env'"
# A 401: the run logs the failed step, exits 1, and never calls claude.
setup
echo 401 >"$T/curl.mode"
run_runner
expect "a 401: exit 1" [ "$rc" -eq 1 ]
expect "a 401: logs the step and the status" grep -q 'HTTP 401' "$T/out"
expect "a 401: no claude call" [ "$(claude_calls)" -eq 0 ]
# app.pem readable by others: check and a run both stop.
setup
chmod 644 "$T/config/jd-cookie-agent/app.pem"
run_runner check
expect "app.pem with mode 644: check exits 1" [ "$rc" -eq 1 ]
expect "app.pem with mode 644: check says so" grep -q 'mode 644' "$T/out"
run_runner
expect "app.pem with mode 644: a run exits 1, with no claude call" [ "$rc/$(claude_calls)" = "1/0" ]
result 5 "the token"

# ---- 6. The agent's limits -----------------------------------------------------------------

setup
export VALKEY_URL=redis://127.0.0.1:6379/0
echo fail-once >"$T/check.mode"
cat >"$T/agent/1" <<'EOF'
mkdir -p scripts/agent-run && echo '{"permissions":{"allow":["Bash"]}}' >scripts/agent-run/settings.json
echo '{"permissions":{"allow":["Bash"]}}' >"$settings"
git add -A && git commit -q -m "chore(repo): settings"
printf 'feat(server): do a thing\n' >.agent/pr.md
git config core.hooksPath .husky
mkdir -p .husky && printf '#!/bin/sh\ntouch "%s/hook-ran"\n' "$STUB_T" >.husky/pre-push && chmod +x .husky/pre-push
git add -A && git commit -q -m "chore(repo): a hook"
EOF
agent_commit 2 'feat(server): do a thing'
run_runner
unset VALKEY_URL
clone=$XDG_DATA_HOME/jd-cookie-agent/repo
expect "the run finished with a PR (exit $rc)" [ "$rc/$(prs)" = "0/1" ]
expect "claude gets --settings" grep -qx -- '--settings' "$T/calls/claude-1.args"
expect "claude gets --strict-mcp-config" grep -qx -- '--strict-mcp-config' "$T/calls/claude-1.args"
expect "try 2's settings are try 1's, whatever the clone's and the filled copy say" cmp -s "$T/calls/claude-1.settings" "$T/calls/claude-2.settings"
expect "the settings come from the runner's folder" bash -c "jq -e '.permissions.allow | index(\"WebSearch\")' '$T/calls/claude-1.settings'"
expect "the settings allow exactly the listed WebFetch domains" [ "$(jq -r '.permissions.allow[] | select(startswith("WebFetch"))' "$T/calls/claude-1.settings" | sort | tr '\n' ' ')" = "WebFetch(domain:developer.mozilla.org) WebFetch(domain:docs.expo.dev) WebFetch(domain:docs.github.com) WebFetch(domain:docs.npmjs.com) WebFetch(domain:fastify.dev) WebFetch(domain:nodejs.org) WebFetch(domain:reactnative.dev) WebFetch(domain:sqlite.org) WebFetch(domain:valkey.io) WebFetch(domain:www.npmjs.com) WebFetch(domain:www.typescriptlang.org) " ]
for d in "$T/config/jd-cookie-agent" "$T/config/gh" "$HOME/.ssh"; do
  expect "the settings deny Read and Edit of $d" bash -c "jq -e --arg r 'Read(/$d/**)' --arg e 'Edit(/$d/**)' '.permissions.deny | index(\$r) and index(\$e)' '$T/calls/claude-1.settings'"
done
expect "no placeholder left in the settings" bash -c "! grep -q '{{' '$T/calls/claude-1.settings'"
for n in 1 2; do
  expect "check $n: no VALKEY_URL, in the sandbox" bash -c "! grep -q '^VALKEY_URL=' '$T/calls/check-$n.env' && grep -qx 'AGENT_RUN_IN_SANDBOX=1' '$T/calls/check-$n.env'"
done
expect "claude has no VALKEY_URL or GIT_CONFIG_COUNT" bash -c "! grep -qE '^(VALKEY_URL|GIT_CONFIG_COUNT)=' '$T/calls/claude-1.env'"
# Every bwrap call for npm run check and the title check has the sandbox's options.
sandboxed=0
for a in "$T/calls/"bwrap-*.args; do
  grep -qx 'npm' "$a" || grep -q 'commitlint' "$a" || continue
  sandboxed=$((sandboxed + 1))
  e=${a%.args}.env
  args=$(tr '\n' ' ' <"$a")
  for want in "--ro-bind / /" "--bind $clone $clone" "--tmpfs $T/config/jd-cookie-agent" "--tmpfs $T/config/gh" "--tmpfs /tmp" "--unshare-pid" "--proc /proc" "--unshare-net" "env AGENT_RUN_IN_SANDBOX=1"; do
    case " $args " in *" $want "*) ;; *) note "$(basename "$a"): missing $want" ;; esac
  done
  [ ! -d "$HOME/.ssh" ] || case " $args " in *" --tmpfs $HOME/.ssh "*) ;; *) note "$(basename "$a"): ~/.ssh isn't masked" ;; esac
  expect "$(basename "$e"): no GH_TOKEN, GIT_CONFIG_COUNT, or VALKEY_URL" bash -c "! grep -qE '^(GH_TOKEN|GIT_CONFIG_COUNT|VALKEY_URL)=' '$e'"
done
# Two npm run check calls (try 1 failed), and one title check (try 2).
expect "npm run check and the title check ran through bwrap (3 calls: $sandboxed)" [ "$sandboxed" -eq 3 ]
expect "npm run check ran only in the sandbox" [ "$(cat "$T/calls"/check-*.env | grep -c '^AGENT_RUN_IN_SANDBOX=1$')" -eq "$(check_calls)" ]
expect "no pre-push hook ran on the runner's pushes" [ ! -e "$T/hook-ran" ]
# The agent edits the clone's .git/config: an insteadOf rewrite and a push URL to a decoy, and
# an fsmonitor command. The runner undoes them before its own git commands.
setup
git init -q --bare "$T/decoy.git"
{
  echo 'echo change >>src/file.txt && git commit -q -am "feat(server): change"'
  echo "printf 'feat(server): do a thing\\n\\nTicket: 0042-thing (docs/tickets/0042-thing.md)\\n' >.agent/pr.md"
  echo "git config url.'$T/decoy.git'.insteadOf '$T/origin.git'"
  echo "git config remote.origin.pushurl '$T/decoy.git'"
  echo "git config core.fsmonitor 'touch $T/fsmonitor-ran; false'"
} >"$T/agent/default"
run_runner
expect "a tampered .git/config: the push went to origin" bash -c "git -C '$T/origin.git' log --format=%s 0042-thing | grep -q 'feat(server): change'"
expect "a tampered .git/config: nothing reached the decoy" [ -z "$(git -C "$T/decoy.git" for-each-ref)" ]
expect "a tampered .git/config: no fsmonitor command ran" [ ! -e "$T/fsmonitor-ran" ]
expect "a tampered .git/config: it's put back" bash -c "! grep -qiE 'insteadOf|pushurl|fsmonitor' '$XDG_DATA_HOME/jd-cookie-agent/repo/.git/config'"

# A check that tampers with .git/config: the push still goes to origin.
setup
git init -q --bare "$T/decoy.git"
echo tamper >"$T/check.mode"
agent_commit default 'feat(server): do a thing'
run_runner
expect "a check that tampers with .git/config: the push went to origin" bash -c "git -C '$T/origin.git' log --format=%s 0042-thing | grep -q 'change 1'"
expect "a check that tampers with .git/config: nothing reached the decoy" [ -z "$(git -C "$T/decoy.git" for-each-ref)" ]
expect "the sandbox mounts the clone's .git read-only" bash -c "grep -A2 -x -- '--ro-bind' \$(grep -lx npm '$T/calls/'bwrap-*.args | head -n 1) | grep -qx '$XDG_DATA_HOME/jd-cookie-agent/repo/.git'"

# The agent links .agent/pr.md to the runner's environment, or hard-links it to the App's key,
# and asks for help: neither reaches the PR, the title check's command line, or a run file.
for kind in environ key; do
  setup
  if [ "$kind" = environ ]; then link='ln -s /proc/self/environ .agent/pr.md'; else link="ln '$T/config/jd-cookie-agent/app.pem' .agent/pr.md"; fi
  printf '%s\necho "Please help." >.agent/stop.md\n' "$link" >"$T/agent/default"
  run_runner
  n=$(last_pr)
  expect "a linked pr.md ($kind): a draft PR with the fallback title" [ "$(pr_json "$n" | jq -r .title)" = 'chore(repo): build ticket 0042-thing' ]
  expect "a linked pr.md ($kind): the token isn't in the PR" bash -c "! grep -qF '$FAKE_TOKEN' '$T/calls/pr-$n.json'"
  expect "a linked pr.md ($kind): the key isn't in the PR" bash -c "! grep -q 'PRIVATE KEY' '$T/calls/pr-$n.json'"
  expect "a linked pr.md ($kind): neither is in a run file or a command line" bash -c "! grep -rqF -e '$FAKE_TOKEN' -e 'PRIVATE KEY' '$T/state' '$T/calls/'*.args"
  expect "a linked pr.md ($kind): the log says it was ignored" grep -q "ignoring .agent/pr.md" "$T/out"
done
# The agent points .git/commondir at a copy of the git folder whose config pushes to a decoy:
# the push still goes to origin.
setup
git init -q --bare "$T/decoy.git"
cat >"$T/agent/default" <<EOF
echo change >>src/file.txt && git commit -q -am "feat(server): change"
printf 'feat(server): do a thing\\n\\nTicket: 0042-thing (docs/tickets/0042-thing.md)\\n' >.agent/pr.md
cp -r .git "$T/alt-git"
git --git-dir="$T/alt-git" config remote.origin.pushurl "$T/decoy.git"
echo "$T/alt-git" >.git/commondir
EOF
run_runner
expect "a .git/commondir: the push went to origin" bash -c "git -C '$T/origin.git' log --format=%s 0042-thing | grep -q 'feat(server): change'"
expect "a .git/commondir: nothing reached the decoy" [ -z "$(git -C "$T/decoy.git" for-each-ref)" ]
expect "a .git/commondir: it's removed" [ ! -e "$XDG_DATA_HOME/jd-cookie-agent/repo/.git/commondir" ]
# The agent hides an uncommitted change behind assume-unchanged: the try still fails.
setup
cat >"$T/agent/1" <<'EOF'
echo x >>src/file.txt && git commit -q -am "feat(server): x"
git update-index --assume-unchanged src/file.txt
echo hidden >>src/file.txt
printf 'feat(server): do a thing\n\nTicket: 0042-thing (docs/tickets/0042-thing.md)\n' >.agent/pr.md
EOF
agent_commit 2 'feat(server): do a thing'
run_runner
expect "assume-unchanged: try 1 failed before the checks" [ "$(claude_calls)/$(check_calls)" = "2/1" ]
expect "assume-unchanged: the fix prompt lists the file" grep -q 'src/file.txt' "$T/calls/claude-2.prompt"
# The agent makes .git/config and .agent/ symlinks to files outside the clone: the runner's
# writes replace the links, and the targets are unchanged.
setup
echo keep >"$T/outside-config"; mkdir -p "$T/outside-agent"
cat >"$T/agent/default" <<EOF
echo change >>src/file.txt && git commit -q -am "feat(server): change"
printf 'feat(server): do a thing\\n\\nTicket: 0042-thing (docs/tickets/0042-thing.md)\\n' >"$T/outside-agent/pr.md"
rm .git/config && ln -s "$T/outside-config" .git/config
rm -rf .agent && ln -s "$T/outside-agent" .agent
EOF
run_runner
expect "symlinked .git/config and .agent: .git/config is a file again" [ ! -L "$XDG_DATA_HOME/jd-cookie-agent/repo/.git/config" ]
expect "symlinked .git/config: its target is unchanged" [ "$(cat "$T/outside-config")" = keep ]
expect "symlinked .agent: its pr.md isn't used (3 tries)" [ "$(claude_calls)" -eq 3 ]

# XDG_RUNTIME_DIR unset: exit 1 with its message, no claude call.
setup
agent_commit default 'feat(server): do a thing'
(unset XDG_RUNTIME_DIR; cd "$repo" && "$runner") >"$T/out" 2>&1; rc=$?
expect "no XDG_RUNTIME_DIR: exit 1, no claude call" [ "$rc/$(claude_calls)" = "1/0" ]
expect "no XDG_RUNTIME_DIR: the message" grep -q "XDG_RUNTIME_DIR isn't set" "$T/out"
# check's sandbox probes fail with a bwrap that doesn't sandbox.
setup
echo direct >"$T/bwrap.mode"
run_runner check
expect "a bwrap that hides nothing: check exits 1" [ "$rc" -eq 1 ]
expect "a bwrap that hides nothing: check says so" grep -q "FAIL: bwrap didn't hide a file" "$T/out"
expect "a bwrap with the host's network: check says so" grep -q "FAIL: bwrap's network isn't empty" "$T/out"
result 6 "the agent's limits"

# ---- 6, with a real bwrap ------------------------------------------------------------------

if [ "$real_bwrap" = no ]; then
  skip 6 "the cases with a real bwrap and a TCP listener (no usable bwrap here, or inside the runner's sandbox)"
else
  # The same arguments the runner used for npm run check, with a real bwrap.
  setup
  agent_commit default 'feat(server): do a thing'
  run_runner
  clone=$XDG_DATA_HOME/jd-cookie-agent/repo
  a=$(grep -lx npm "$T/calls/"bwrap-*.args | head -n 1)
  mapfile -t sb <"$a"
  sb=("${sb[@]:0:${#sb[@]}-3}")     # drop "npm run check"
  # check's two sandbox probes pass with the real bwrap (the other stubs stay).
  mkdir -p "$T/realbin"
  ln -sf "$real_bwrap" "$T/realbin/bwrap"
  (export PATH="$T/realbin:$T/bin:$ORIG_PATH"; cd "$repo" && "$runner" check) >"$T/out" 2>&1
  expect "the real bwrap: check's probes pass" bash -c "grep -q 'ok: bwrap hides a masked folder' '$T/out' && grep -q 'ok: bwrap has no network' '$T/out'"
  export PATH=$ORIG_PATH
  # A secret file can't be read inside, and a listener the test reached from outside can't be
  # reached from inside.
  echo secret >"$T/config/jd-cookie-agent/secret.txt"
  expect "the real bwrap: a secret file is hidden" bash -c "! '$real_bwrap' \"\$@\" cat '$T/config/jd-cookie-agent/secret.txt'" _ "${sb[@]}"
  port_file=$T/port
  node -e 'const s=require("net").createServer(c=>c.end("hi")).listen(0,"127.0.0.1",()=>{require("fs").writeFileSync(process.argv[1],String(s.address().port))}); setTimeout(()=>s.close(),20000)' "$port_file" &
  server=$!
  for _ in $(seq 50); do [ -s "$port_file" ] && break; sleep 0.1; done
  port=$(cat "$port_file")
  connect='const c=require("net").connect(+process.argv[1],"127.0.0.1",()=>{process.exit(0)});c.on("error",()=>process.exit(1));setTimeout(()=>process.exit(1),3000)'
  expect "the listener answers from outside" node -e "$connect" "$port"
  expect "the real bwrap: the listener can't be reached from inside" bash -c "! '$real_bwrap' \"\$@\" node -e '$connect' $port" _ "${sb[@]}"
  kill "$server" 2>/dev/null; wait "$server" 2>/dev/null
  # The whole suite passes inside the sandbox, as the runner runs it, with these cases skipped.
  sbr=()
  for x in "${sb[@]}"; do
    # A node_modules that links elsewhere (as in the pre-commit hook's snapshot) is bound too,
    # read-only, since the sandbox's /tmp is empty.
    if [ "$x" = --chdir ] && [ -L "$repo/node_modules" ]; then
      nm=$(readlink -f "$repo/node_modules")
      sbr+=(--ro-bind "$nm" "$nm")
    fi
    sbr+=("${x//$clone/$repo}")
  done
  # The hook's snapshot has no .git: drop its read-only mount then.
  if [ ! -e "$repo/.git" ]; then
    keep=()
    for ((i = 0; i < ${#sbr[@]}; i++)); do
      if [ "${sbr[i]}" = --ro-bind ] && [ "${sbr[i+1]}" = "$repo/.git" ]; then i=$((i + 2)); continue; fi
      keep+=("${sbr[i]}")
    done
    sbr=("${keep[@]}")
  fi
  "$real_bwrap" "${sbr[@]}" npm run test:scripts >"$T/inner.out" 2>&1
  inner=$?
  expect "the real bwrap: npm run test:scripts passes inside it (exit $inner): $(grep -E '^not ok' "$T/inner.out" | head -n 3 | tr '\n' ' ')" [ "$inner" -eq 0 ]
  expect "inside the sandbox, the real-bwrap cases are skipped" grep -q '^skip 6' "$T/inner.out"
  result 6 "the agent's limits, with a real bwrap"
fi

[ "$failures" -eq 0 ] || exit 1
