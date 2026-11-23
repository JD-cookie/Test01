#!/usr/bin/env bash
# The runner: builds the next ready ticket into a PR, with Claude Code in headless mode.
#
#   scripts/agent-run.sh          # one run: one step for the runner's own ticket, then exit
#   scripts/agent-run.sh check    # check the tools, the sandbox, and the App's key; change nothing
#
# One run (see docs/features/0007-agent-runner.md for the whole design):
#   1. Take the lock, so only one run works at a time on this machine.
#   2. Find its work: its own claim branches on origin (Claimed-By: runner-<machine id>).
#      An open PR means it's in review: exit. A branch with no PR means a run died while
#      building it: stop for help. Otherwise, claim the next free ready ticket and build it.
#   3. Build: the agent builds it and commits; the runner runs the checks itself, in a bwrap
#      sandbox with no network, up to 3 tries; then it pushes and opens the PR as the App.
#   4. Whenever it can't go on, it stops for help: it saves the work, pushes it, and opens a
#      draft PR with the label needs-help whose description says why.
#
# The runner keeps no state between runs: the state is the ticket's branch, its PR, and the
# PR's labels, on GitHub. It works in its own clone, never in the user's checkout, and reads
# nothing it trusts from that clone: its prompts and Claude settings come from scripts/agent-run/
# beside this script, and the commitlint config from origin/main.
#
# Exit codes: 0 done (including "nothing to do" and "stopped for help"), 1 failed: see the log.
set -euo pipefail

# Git's own variables, set when this runs from a git hook, would point every git command at
# another repo instead of the runner's clone.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY GIT_PREFIX
# Git may only use https (the repo's URL), whatever a config says: no ext:: or other transport
# that runs a command. The tests set file instead, for their local origin.
export GIT_ALLOW_PROTOCOL=${GIT_ALLOW_PROTOCOL:-https}

# ---- Constants -----------------------------------------------------------------------------

OWNER=JD-cookie
REPO=Test01
BOT_LOGIN='jd-cookie-agent[bot]'
TRIES=3                     # tries to get the checks green, then stop for help
OUTPUT_LINES=200            # lines of a failed check's output given to the fix try and the PR
KEEP_LOGS=200               # run logs kept
LABEL_RUN=agent-run
LABEL_HELP=needs-help
# The first line of a stop's PR description, which find_work recognizes.
STOP_MARK='**The runner stopped for help.**'
DESC_MAX=60000              # GitHub's limit on a PR's description is 65,536 characters
REASON_MAX=5000
# Claude's usage limit, recognized only when claude also exits non-zero (case-insensitive,
# extended regular expressions, matched against the last 20 lines of its output).
LIMIT_PATTERNS=('usage limit reached' 'hit your limit' 'limit reached.*resets')

# Time limits. The AGENT_RUN_*_TIME and AGENT_RUN_KILL_AFTER overrides are for the tests only.
AGENT_TIME=${AGENT_RUN_AGENT_TIME:-45m}
CHECK_TIME=${AGENT_RUN_CHECK_TIME:-20m}
TITLE_TIME=${AGENT_RUN_TITLE_TIME:-2m}
AGENT_KILL=${AGENT_RUN_KILL_AFTER:-1m}
CHECK_KILL=${AGENT_RUN_KILL_AFTER:-1m}
TITLE_KILL=${AGENT_RUN_KILL_AFTER:-10s}

# ---- Paths ---------------------------------------------------------------------------------

self_dir=$(cd "$(dirname "$0")" && pwd)
prompts=$self_dir/agent-run
token_sh=$self_dir/agent-token.sh
data=${XDG_DATA_HOME:-$HOME/.local/share}/jd-cookie-agent
clone=$data/repo
state=${XDG_STATE_HOME:-$HOME/.local/state}/jd-cookie-agent
# The secret folders: masked in the sandbox, and denied to the agent by its Claude settings.
config=${XDG_CONFIG_HOME:-$HOME/.config}/jd-cookie-agent
gh_config=${GH_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/gh}
ssh_dir=$HOME/.ssh
npm_cache=${npm_config_cache:-$HOME/.npm}
# For the tests only: AGENT_RUN_ORIGIN (the clone's origin) and AGENT_RUN_MACHINE_ID_FILE.
origin_url=${AGENT_RUN_ORIGIN:-https://github.com/$OWNER/$REPO.git}
machine_id_file=${AGENT_RUN_MACHINE_ID_FILE:-/etc/machine-id}

# ---- Helpers -------------------------------------------------------------------------------

log() { printf '%s %s\n' "$(date -u +%H:%M:%S)" "$*"; }
fail() { log "error: $*"; exit 1; }

# Runs "$@" without the token, the credential helper, or VALKEY_URL in its environment: for
# claude, npm, the checks, and the title check.
no_token() {
  env -u GH_TOKEN -u GIT_CONFIG_COUNT -u GIT_CONFIG_KEY_0 -u GIT_CONFIG_VALUE_0 \
    -u GIT_CONFIG_KEY_1 -u GIT_CONFIG_VALUE_1 -u VALKEY_URL "$@"
}

# A new App token, for the next group of GitHub calls and pushes. git gets it through a
# credential helper set in the environment only, never in the clone's config or a file.
new_token() {
  local t
  t=$("$token_sh" 3>&1 1>&2) || fail "making the App's token failed (see above)"
  export GH_TOKEN=$t
  export GIT_CONFIG_COUNT=2
  export GIT_CONFIG_KEY_0=credential.helper GIT_CONFIG_VALUE_0=
  export GIT_CONFIG_KEY_1=credential.helper
  # shellcheck disable=SC2016 # expanded by the shell git starts for the helper, not here
  # It answers only "get" requests for https://github.com, the repo's host.
  export GIT_CONFIG_VALUE_1='!f() { [ "$1" = get ] || exit 0; ok=; while read -r l && [ -n "$l" ]; do [ "$l" = host=github.com ] && ok=1; done; [ -n "$ok" ] && { echo username=x-access-token; echo "password=$GH_TOKEN"; }; }; f'
}

# Removes the token and the credential helper from the runner's environment, so nothing runs
# with them until the next new_token.
drop_token() {
  unset GH_TOKEN GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0 GIT_CONFIG_KEY_1 GIT_CONFIG_VALUE_1
}

# gh, always against this repo's API. Logs the call (never the token) and its exit code.
gh_api() {
  local rc=0
  gh api "$@" || rc=$?
  # To stderr, so a caller's $(…) doesn't swallow it. The arguments hold no secrets.
  [ "$rc" -eq 0 ] || log "gh api $*: exit $rc" >&2
  return "$rc"
}

# The runner's own git commands in the clone. The agent can edit .git/config, so they run no
# hooks and no fsmonitor, and the config itself is rewritten (write_config) before them.
git_c() { git -C "$clone" -c core.hooksPath=/dev/null -c core.fsmonitor=false "$@"; }

# Writes the clone's .git/config and .git/info/exclude from scratch, with only what the runner
# needs: origin, and husky's hook path for the agent's own commits. Anything the agent or a
# check wrote there (an insteadOf rewrite, a push URL, an include, a hook path) is gone. It's
# written, not copied back, because a saved copy would be a file the agent could edit too.
write_config() {
  # .git must be the clone's own folder: if the agent made it a symlink, the writes below would
  # land in whatever folder it points to.
  if [ -L "$clone/.git" ] || [ ! -d "$clone/.git" ]; then
    fail "the clone's .git isn't a folder (a symlink, or missing): not using it"
  fi
  # rm first: if the agent made one a symlink, writing through it would change its target.
  [ ! -L "$clone/.git/info" ] || rm -f "$clone/.git/info"
  rm -f "$clone/.git/config" "$clone/.git/info/exclude"
  cat >"$clone/.git/config" <<EOF
[core]
	repositoryformatversion = 0
	filemode = true
	bare = false
	logallrefupdates = true
	hooksPath = .husky/_
[remote "origin"]
	url = $origin_url
	fetch = +refs/heads/*:refs/remotes/origin/*
EOF
  mkdir -p "$clone/.git/info"
  printf '%s\n' '.agent/' >"$clone/.git/info/exclude"
  # .git/commondir would point git at another folder's config, objects, and refs.
  rm -f "$clone/.git/commondir"
  local common
  common=$(git -C "$clone" rev-parse --path-format=absolute --git-common-dir) &&
    [ "$(realpath "$common")" = "$(realpath "$clone/.git")" ] ||
    fail "the clone's git folder points somewhere else ($common): not using it"
}

# Copies the agent's files (.agent/pr.md, .agent/stop.md) to $agent_files, and reads them only
# from there. Only a regular file with one link counts: a symlink (to /proc/self/environ, say)
# or a hard link (to the App's key) would make the runner read something else. Run it with no
# token in the environment, since a file the runner reads can't then hold one.
take_agent_files() {
  rm -rf "$agent_files"
  mkdir -p "$agent_files"
  local f rc
  for f in pr.md stop.md; do
    # node opens the file without following a symlink (O_NOFOLLOW), checks the file it opened
    # (fstat), and reads from that same descriptor, so nothing can be swapped in between a
    # check and the copy. O_NONBLOCK: opening a FIFO doesn't wait for a writer, and fstat then
    # refuses it; timeout is a last guard against anything else that blocks. Exit 2: no file.
    rc=0
    timeout 30s node -e '
      const fs = require("fs"), path = require("path");
      const [dir, name, dest] = process.argv.slice(1);
      let d;
      try { d = fs.lstatSync(dir); } catch { process.exit(2); }
      if (!d.isDirectory()) process.exit(1);
      let fd;
      try { fd = fs.openSync(path.join(dir, name), fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW | fs.constants.O_NONBLOCK); }
      catch (e) { process.exit(e.code === "ENOENT" ? 2 : 1); }
      const s = fs.fstatSync(fd);
      if (!s.isFile() || s.nlink !== 1) process.exit(1);
      fs.writeFileSync(dest, fs.readFileSync(fd));
    ' "$clone/.agent" "$f" "$agent_files/$f" || rc=$?
    if [ "$rc" -ne 0 ] && [ "$rc" -ne 2 ]; then
      rm -f "$agent_files/$f"
      log "ignoring .agent/$f: it isn't a regular file with one link"
      : >"$agent_files/$f.refused"
    fi
  done
}

# Pushes HEAD to the branch $1 without hooks: the agent can edit .husky/, and a hook it added
# would run while the token is in the environment. Prints git's output. Exit code is git's.
push_branch() {
  git_c push -q origin "HEAD:refs/heads/$1" 2>&1
}

# Fills a template's {{NAME}} placeholders. Arguments: template, destination, then NAME and a
# value, or NAME and @file to read the value from a file. Values aren't re-scanned.
fill() {
  node -e '
    const fs = require("fs");
    const [src, dest, ...pairs] = process.argv.slice(1);
    const values = {};
    for (let i = 0; i < pairs.length; i += 2) {
      const v = pairs[i + 1];
      values[pairs[i]] = v.startsWith("@") ? fs.readFileSync(v.slice(1), "utf8") : v;
    }
    const out = fs.readFileSync(src, "utf8").replace(/\{\{([A-Z_]+)\}\}/g,
      (m, k) => (k in values ? values[k] : m));
    fs.writeFileSync(dest, out);
  ' "$@"
}

# ---- The sandbox ---------------------------------------------------------------------------

# Sets SANDBOX to the command that runs a command in bwrap: the file system read-only except
# the clone, a private /tmp, and the npm cache; empty folders over the secret folders; its own
# process list and an empty network. The token, the credential helper, and VALKEY_URL are
# removed from its environment. An array, not a function, so timeout can run it.
sandbox_cmd() {
  SANDBOX=(env -u GH_TOKEN -u GIT_CONFIG_COUNT -u GIT_CONFIG_KEY_0 -u GIT_CONFIG_VALUE_0
    -u GIT_CONFIG_KEY_1 -u GIT_CONFIG_VALUE_1 -u VALKEY_URL
    bwrap --ro-bind / / --dev /dev --proc /proc)
  local d
  for d in "$config" "$gh_config" "$ssh_dir"; do
    [ -d "$d" ] && SANDBOX+=(--tmpfs "$d")
  done
  # The clone is writable, but its .git isn't: a check can't add a push URL or a hook.
  SANDBOX+=(--tmpfs /tmp --bind "$clone" "$clone")
  [ -e "$clone/.git" ] && SANDBOX+=(--ro-bind "$clone/.git" "$clone/.git")
  [ -d "$npm_cache" ] && SANDBOX+=(--bind "$npm_cache" "$npm_cache")
  SANDBOX+=(--unshare-pid --unshare-net --die-with-parent --chdir "$clone" env AGENT_RUN_IN_SANDBOX=1)
}

# ---- Checking the setup --------------------------------------------------------------------

# Prints a line per check, and returns 1 if any failed. Writes nothing outside a temporary
# folder, and changes nothing on GitHub.
setup_checks() {
  local bad=0 c tmp
  for c in claude gh node npm curl openssl flock bwrap git timeout; do
    if command -v "$c" >/dev/null; then echo "ok: $c is on PATH"; else echo "FAIL: $c isn't on PATH"; bad=1; fi
  done
  if command -v bwrap >/dev/null; then
    tmp=$(mktemp -d)
    echo probe >"$tmp/agent-run-probe-secret"
    if bwrap --ro-bind / / --dev /dev --proc /proc --tmpfs "$tmp" --unshare-pid --unshare-net \
      cat "$tmp/agent-run-probe-secret" >/dev/null 2>&1; then
      echo "FAIL: bwrap didn't hide a file (it could read $tmp/agent-run-probe-secret)"; bad=1
    else
      echo "ok: bwrap hides a masked folder"
    fi
    rm -rf "$tmp"
    # /proc/net/dev lists the sandbox's own interfaces. /sys/class/net would show the host's.
    local ifaces
    if ifaces=$(bwrap --ro-bind / / --dev /dev --proc /proc --unshare-pid --unshare-net \
      cat /proc/net/dev 2>/dev/null | awk -F: 'NR > 2 { gsub(/ /, "", $1); print $1 }'); then
      if [ "$ifaces" = lo ]; then
        echo "ok: bwrap has no network (only lo)"
      else
        echo "FAIL: bwrap's network isn't empty: $(printf '%s' "$ifaces" | tr '\n' ' ')"; bad=1
      fi
    else
      echo "FAIL: bwrap couldn't start a sandbox with --unshare-net"; bad=1
    fi
  fi
  if [ ! -f "$config/app.pem" ]; then
    echo "FAIL: the App's private key is missing: $config/app.pem"; bad=1
  elif [ "$(stat -c %a "$config/app.pem")" != 600 ]; then
    echo "FAIL: $config/app.pem has mode $(stat -c %a "$config/app.pem"): it must be 600"; bad=1
  else
    echo "ok: $config/app.pem exists, with mode 600"
  fi
  if grep -q '^APP_CLIENT_ID=.' "$config/app.env" 2>/dev/null; then
    echo "ok: $config/app.env sets APP_CLIENT_ID"
  else
    echo "FAIL: $config/app.env must set APP_CLIENT_ID"; bad=1
  fi
  if [ "$bad" -eq 0 ]; then
    if (t=$("$token_sh" 3>&1 1>&2) && [ -n "$t" ]); then
      echo "ok: made a token for the App"
    else
      echo "FAIL: couldn't make a token for the App (see above)"; bad=1
    fi
  fi
  return "$bad"
}

# ---- The PR --------------------------------------------------------------------------------

# Creates the labels this run needs, if they don't exist yet.
ensure_labels() {
  local have name
  have=$(gh_api --paginate "repos/$OWNER/$REPO/labels?per_page=100" --jq '.[].name') ||
    fail "couldn't list the repo's labels"
  for name in "$@"; do
    # A here-string, not a pipe: grep -q stops at the first match, which under pipefail would
    # fail a long writer with SIGPIPE.
    grep -qxF -- "$name" <<<"$have" && continue
    log "creating the label $name"
    gh_api -X POST "repos/$OWNER/$REPO/labels" -f name="$name" -f color=ededed \
      -f description="Set by the runner, scripts/agent-run.sh" >/dev/null || fail "couldn't create the label $name"
  done
}

# Opens a PR from the branch $1. $2 is a file with the title, $3 a file with the body, $4 is
# true for a draft, and the rest are its labels. The title, body, and draft go in one call;
# labels are added after it.
open_pr() {
  local branch=$1 title_file=$2 body_file=$3 draft=$4
  shift 4
  new_token
  ensure_labels "$@"
  local req number label_args=()
  req=$(mktemp)
  node -e '
    const fs = require("fs");
    const [t, b, head, draft, out] = process.argv.slice(1);
    fs.writeFileSync(out, JSON.stringify({ title: fs.readFileSync(t, "utf8").trim(),
      body: fs.readFileSync(b, "utf8"), head, base: "main", draft: draft === "true" }));
  ' "$title_file" "$body_file" "$branch" "$draft" "$req"
  number=$(gh_api -X POST "repos/$OWNER/$REPO/pulls" --input "$req" --jq .number) ||
    { rm -f "$req"; fail "opening the PR failed"; }
  rm -f "$req"
  for label in "$@"; do label_args+=(-f "labels[]=$label"); done
  gh_api -X POST "repos/$OWNER/$REPO/issues/$number/labels" "${label_args[@]}" >/dev/null ||
    fail "PR #$number is open, but adding its labels failed"
  log "opened PR #$number ($(tr -d '\n' <"$title_file"))"
}

# ---- The agent and the checks --------------------------------------------------------------

# Runs the agent once. $1 is the try number, $2 the filled prompt. Its output goes to the log
# and to $run/agent-<try>.out. Returns claude's exit code (124 or 137 when it timed out).
run_agent() {
  local try=$1 prompt=$2 rc=0
  rm -rf "$clone/.agent"
  mkdir -p "$clone/.agent"
  log "try $try of $TRIES: running the agent"
  (cd "$clone" && no_token timeout --kill-after="$AGENT_KILL" "$AGENT_TIME" \
    claude -p --strict-mcp-config --settings "$run/settings.json" <"$prompt" 9>&-) \
    2>&1 | tee "$run/agent-$try.out" || rc=$?
  log "the agent exited with $rc"
  return "$rc"
}

# Prints the line of the agent's output that shows Claude's usage limit, or returns 1.
limit_line() {
  local p line
  for p in "${LIMIT_PATTERNS[@]}"; do
    if line=$(tail -n 20 "$1" | grep -iE -- "$p" | tail -n 1) && [ -n "$line" ]; then
      printf '%s\n' "$line"
      return 0
    fi
  done
  return 1
}

# Checks a title with commitlint and main's config, in the sandbox. Output goes to $2.
title_check() {
  local title=$1 out=$2
  # .agent/ is the agent's: if it made the folder or the file a symlink, writing through it would
  # change something else. So both are made fresh.
  if [ -L "$clone/.agent" ] || [ ! -d "$clone/.agent" ]; then rm -rf "$clone/.agent"; mkdir -p "$clone/.agent"; fi
  rm -rf "$clone/.agent/commitlint.config.mjs"
  git_c show origin/main:commitlint.config.mjs >"$clone/.agent/commitlint.config.mjs" ||
    { echo "couldn't read commitlint.config.mjs on origin/main" >"$out"; return 1; }
  # shellcheck disable=SC2016 # expanded inside the sandbox
  sandbox_cmd
  timeout --kill-after="$TITLE_KILL" "$TITLE_TIME" \
    "${SANDBOX[@]}" AGENT_RUN_TITLE="$title" sh -c \
    'printf "%s\n" "$AGENT_RUN_TITLE" | ./node_modules/.bin/commitlint --config .agent/commitlint.config.mjs' \
    >"$out" 2>&1 9>&-
}

# The checks after a try. Returns 0 if everything passes; otherwise leaves what failed in $1.
checks() {
  local out=$1 head status rc=0
  # A fresh index from HEAD: an assume-unchanged or skip-worktree flag the agent set would
  # otherwise hide a changed file (a package.json whose check is "true") from git status.
  git_c read-tree HEAD || { echo "git read-tree HEAD failed" >"$out"; return 1; }
  status=$(git_c status --porcelain) || { echo "git status failed" >"$out"; return 1; }
  if [ -n "$status" ]; then
    { echo "The clone has changes that aren't committed. Commit them, or remove them:"; echo "$status"; } >"$out"
    return 1
  fi
  head=$(git_c rev-parse HEAD)
  log "running npm run check in the sandbox"
  sandbox_cmd
  (timeout --kill-after="$CHECK_KILL" "$CHECK_TIME" "${SANDBOX[@]}" npm run check 9>&-) >"$out" 2>&1 || rc=$?
  if [ "$rc" -ne 0 ]; then
    [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ] && echo "npm run check ran out of time ($CHECK_TIME) and was stopped." >>"$out"
    log "npm run check failed (exit $rc)"
    return 1
  fi
  if ! first_line "$agent_files/pr.md" >/dev/null; then
    if [ -e "$agent_files/pr.md.refused" ]; then
      echo "The agent's .agent/pr.md isn't a regular file with one link (a symlink or a hard link), so it doesn't count. Write it as a plain file." >"$out"
    else
      echo "The agent didn't write .agent/pr.md, or its first line (the PR's title) is empty." >"$out"
    fi
    return 1
  fi
  # One awk reads the file, with no pipe for pipefail to trip on when the body is long.
  local want="Ticket: $ticket (docs/tickets/$ticket.md)" got
  got=$(awk 'NR > 1 && $0 !~ /^[[:space:]]*$/ { sub(/[[:space:]]+$/, ""); print; exit }' "$agent_files/pr.md")
  local size
  size=$(node -e 'const fs = require("fs"); const t = fs.readFileSync(process.argv[1], "utf8"); const i = t.indexOf("\n"); process.stdout.write(String(i < 0 ? 0 : [...t.slice(i + 1)].length))' "$agent_files/pr.md")
  if [ "$size" -gt "$DESC_MAX" ]; then
    echo "The PR body in .agent/pr.md has $size characters: keep it under $DESC_MAX (GitHub's limit is 65,536). Put long output in the ticket doc's Delivery and review instead." >"$out"
    return 1
  fi
  if [ "$got" != "$want" ]; then
    echo "The PR body in .agent/pr.md (after the title) must start with the line: $want, as next-ticket step 3 says. Its first line is: ${got:-(none)}" >"$out"
    return 1
  fi
  log "checking the PR's title with commitlint"
  if ! title_check "$(first_line "$agent_files/pr.md")" "$out.title"; then
    { echo "The PR title in .agent/pr.md fails commitlint, with main's config:"; cat "$out.title"; } >"$out"
    log "the title check failed"
    return 1
  fi
  status=$(git_c status --porcelain)
  if [ -n "$status" ] || [ "$(git_c rev-parse HEAD)" != "$head" ]; then
    { echo "The checks changed the clone, so they didn't test what would be pushed:"; echo "$status"; } >"$out"
    return 1
  fi
  return 0
}

# Prints the first line of a file if it's not empty, or returns 1.
first_line() {
  local l
  [ -f "$1" ] && l=$(head -n 1 "$1") && [ -n "${l// /}" ] && printf '%s\n' "$l"
}

# ---- Stopping for help ---------------------------------------------------------------------

# Saves the work, pushes it, and opens a draft PR with needs-help. $1 is the branch, $2 a file
# with the reason, $3 a file with output (may be empty or missing), $4 "refused" if GitHub
# refused the push (then nothing is pushed). Exits 0.
stop_for_help() {
  local branch=$1 reason=$2 output=${3:-} refused=${4:-}
  mkdir -p "$run"
  log "stopping for help: $(head -n 1 "$reason")"
  # The agent's files are read with no token in the environment (see take_agent_files). After a
  # try they're already copied; on the way from find_work they aren't yet.
  drop_token
  [ -d "$agent_files" ] || take_agent_files
  write_config
  new_token
  git_c fetch -q origin || fail "couldn't fetch origin"
  local base saved=()
  # The newest commit both HEAD and origin's branch have, so the bundle (if any) and the patch
  # rebuild HEAD exactly, even if origin's branch moved on while HEAD stayed behind.
  # If HEAD shares no commit with either (its history was rewritten), there's no base: base.txt
  # says "none", and the bundle holds HEAD's whole history.
  base=
  if git_c rev-parse -q --verify "refs/remotes/origin/$branch" >/dev/null; then
    base=$(git_c merge-base HEAD "origin/$branch") || base=
  fi
  [ -n "$base" ] || base=$(git_c merge-base HEAD origin/main) || base=
  echo "${base:-none}" >"$run/base.txt"
  saved+=(base.txt)
  if [ -z "$base" ]; then
    git_c bundle create -q "$run/commits.bundle" HEAD
    saved+=(commits.bundle)
  elif [ -n "$(git_c rev-list "$base..HEAD")" ]; then
    git_c bundle create -q "$run/commits.bundle" "$base..HEAD"
    saved+=(commits.bundle)
  fi
  git_c add -A
  if ! git_c diff --cached --quiet HEAD; then
    git_c diff --cached --binary HEAD >"$run/uncommitted.patch"
    saved+=(uncommitted.patch)
  fi
  git_c reset -q
  local pushed_note=""
  if [ "$refused" != refused ] && { [ -z "$base" ] || [ -n "$(git_c rev-list "$base..HEAD")" ]; }; then
    local out
    if out=$(push_branch "$branch"); then
      log "pushed the work so far to $branch"
    else
      printf '%s\n' "$out"
      if grep -qi 'workflow' <<<"$out"; then
        pushed_note="GitHub refused the push, because the branch changes a workflow. The branch on GitHub has only what was there before."
      else
        pushed_note="The push failed, so the branch on GitHub has only what was there before."
      fi
    fi
  elif [ "$refused" = refused ]; then
    pushed_note="Nothing was pushed: GitHub refuses the App's pushes that change .github/workflows/. The branch on GitHub has only what was there before."
  fi
  # The title: from pr.md if it passes the check, or a fallback.
  local title_file=$run/pr-title.txt body_file=$run/pr-body.txt pr_body=$run/agent-pr-body.txt
  : >"$pr_body"
  local t
  if t=$(first_line "$agent_files/pr.md") && title_check "$t" "$run/title-check.out"; then
    printf '%s\n' "$t" >"$title_file"
    tail -n +2 "$agent_files/pr.md" >"$pr_body"
  else
    printf 'chore(repo): build ticket %s\n' "$branch" >"$title_file"
    [ ! -f "$agent_files/pr.md" ] || cp "$agent_files/pr.md" "$pr_body"
  fi
  printf '%s\n' "$pushed_note" >"$run/push-note.txt"
  [ -n "$output" ] && [ -f "$output" ] || output=/dev/null
  node -e '
    const fs = require("fs");
    const [reasonF, outputF, bodyF, noteF, runDir, saved, max, reasonMax, out, stopMark] = process.argv.slice(1);
    const cutEnd = (s, n) => s.length <= n ? s : s.slice(0, n) + "\n\n(cut to " + n + " characters; the whole text is in the run folder)";
    const cutStart = (s, n) => s.length <= n ? s : "(the first " + (s.length - n) + " characters are cut; the whole text is in the run folder)\n" + s.slice(s.length - n);
    const reason = cutEnd(fs.readFileSync(reasonF, "utf8").trim(), +reasonMax);
    const note = fs.readFileSync(noteF, "utf8").trim();
    let head = stopMark + "\n\n" + reason + "\n\n" +
      (note ? note + "\n\n" : "") +
      "Run folder: `" + runDir + "`, with " + saved.split(" ").map(f => "`" + f + "`").join(", ") +
      ". To restore the work in a fresh clone: check out the commit in `base.txt` (if it says `none`, skip this: the bundle has the whole history); if `commits.bundle` is there, `git fetch <run folder>/commits.bundle HEAD` and `git checkout FETCH_HEAD`; if `uncommitted.patch` is there, `git apply` it.\n\n" +
      "Fix what is needed by hand, then mark this PR ready for review.\n";
    let output = fs.readFileSync(outputF, "utf8").trim();
    let body = fs.readFileSync(bodyF, "utf8").trim();
    // Fences in the output are escaped before anything is measured or cut, so the cut fits.
    const fence = s => "\n## Output\n\n```\n" + s + "\n```\n";
    const bodyPart = s => "\n## The agent’s PR description\n\n" + s + "\n";
    const compose = (o, b) => head + (o ? fence(o) : "") + (b ? bodyPart(b) : "");
    // Room for the output and the body: what is left after the head and the wrappers,
    // with space for the notes that say a text was cut.
    let left = +max - compose("x", "x").length - 400;
    let o = output.replace(/```/g, "` ` `"), b = body;
    if (o.length + b.length > left) {
      const half = Math.floor(left / 2);
      if (o.length <= half) b = cutStart(b, left - o.length);
      else if (b.length <= half) o = cutStart(o, left - b.length);
      else { o = cutStart(o, half); b = cutStart(b, left - half); }
    }
    const text = compose(o, b);
    if (text.length >= +max) throw new Error("the description is still too long: " + text.length);
    fs.writeFileSync(out, text);
  ' "$reason" "$output" "$pr_body" "$run/push-note.txt" "$run" "${saved[*]}" "$DESC_MAX" "$REASON_MAX" "$body_file" "$STOP_MARK"
  open_pr "$branch" "$title_file" "$body_file" true "$LABEL_RUN" "$LABEL_HELP"
  exit 0
}

# Writes $1 to a reason file in the run folder and prints its path.
reason_file() {
  mkdir -p "$run"
  printf '%s\n' "$1" >"$run/reason.txt"
  printf '%s\n' "$run/reason.txt"
}

# ---- Finding its work ----------------------------------------------------------------------

# Makes sure the clone exists, with origin pointing at the repo.
ensure_clone() {
  if [ ! -d "$clone/.git" ]; then
    mkdir -p "$data"
    log "cloning $origin_url into $clone"
    git clone -q "$origin_url" "$clone" || fail "cloning failed"
  fi
  # .agent/ is ignored by the repo's .gitignore too; write_config keeps it ignored whatever the
  # branch says, and drops anything else the agent added to .git/info/exclude.
  write_config
}

# Looks at the runner's own claim branches. Exits if one has an open PR, stops for help on one
# with no PR, and returns if there's nothing in progress.
find_work() {
  git_c fetch -q --prune origin || fail "couldn't fetch origin"
  local heads b claim who prs
  heads=$(git_c ls-remote --heads origin) || fail "couldn't list origin's branches"
  for b in $(printf '%s\n' "$heads" | sed -n 's#.*refs/heads/\([0-9][0-9][0-9][0-9]-[a-z0-9-]*\)$#\1#p'); do
    # awk reads all of rev-list's output, so a long branch can't end it with SIGPIPE.
    claim=$(git_c rev-list --topo-order --reverse "origin/main..origin/$b" | awk 'NR == 1')
    [ -n "$claim" ] || continue
    who=$(git_c log -1 --format='%(trailers:key=Claimed-By,valueonly)' "$claim" | tr -d '[:space:]')
    [ "$who" = "$agent" ] || continue
    # Each line: number, state, whether it has agent-run, whether its description is a stop.
    prs=$(gh_api --paginate "repos/$OWNER/$REPO/pulls?state=all&head=$OWNER:$b&per_page=100" \
      --jq ".[] | \"\\(.number) \\(.state) \\([.labels[]?.name] | index(\"$LABEL_RUN\") != null) \\((.body // \"\") | startswith(\"$STOP_MARK\"))\"") ||
      fail "couldn't list the PRs of $b"
    local open
    open=$(awk '$2 == "open" && !found { print; found = 1 }' <<<"$prs")
    if [ -n "$open" ]; then
      local n has_label stopped
      read -r n _ has_label stopped <<<"$open"
      # A PR whose labels call failed has neither label. Add them back, once: a PR that has
      # agent-run is left as it is, so a needs-help the user removed isn't added again.
      if [ "$has_label" = false ]; then
        local labels=(-f "labels[]=$LABEL_RUN")
        [ "$stopped" = true ] && labels+=(-f "labels[]=$LABEL_HELP")
        log "PR #$n has no $LABEL_RUN label: adding its labels"
        ensure_labels "$LABEL_RUN" "$LABEL_HELP"
        gh_api -X POST "repos/$OWNER/$REPO/issues/$n/labels" "${labels[@]}" >/dev/null ||
          fail "adding the labels of PR #$n failed"
      fi
      log "PR #$n is open"
      exit 0
    elif [ -n "$prs" ]; then
      log "$b: its PR is closed or merged, skipping it"
    else
      log "$b has no PR: a run stopped while building it"
      local current
      current=$(git_c symbolic-ref -q --short HEAD || true)
      if [ "$current" != "$b" ]; then
        if git_c show-ref -q --verify "refs/heads/$b" &&
          [ -n "$(git_c rev-list "origin/$b..refs/heads/$b")" ]; then
          git_c switch -q -f "$b"
        else
          git_c switch -q -f -C "$b" "origin/$b"
        fi
      fi
      stop_for_help "$b" "$(reason_file "A run stopped while building this ticket. Its work so far is on this branch.")"
    fi
  done
}

# ---- Building ------------------------------------------------------------------------------

build() {
  log "updating the clone to origin/main"
  git_c switch -q -f -C main origin/main
  git_c reset -q --hard origin/main
  # -x: ignored files go too, so nothing an earlier ticket's agent left (a hook it hid from git,
  # an old .agent/pr.md) reaches this ticket's claim. npm ci reinstalls node_modules anyway.
  git_c clean -q -ffdx
  rm -rf "$clone/.agent"
  local b
  for b in $(git_c for-each-ref --format='%(refname:short)' refs/heads); do
    [ "$b" = main ] || git_c branch -q -D "$b"
  done
  local listed
  listed=$(cd "$clone" && scripts/ticket.sh list) || fail "scripts/ticket.sh list failed"
  if ! awk '$2 == "ready" && NF == 2 { found = 1 } END { exit !found }' <<<"$listed"; then
    log "no ready ticket"
    exit 0
  fi
  log "installing the clone's dependencies"
  local part
  for part in . server app; do
    (cd "$clone/$part" && no_token npm ci 9>&-) || fail "npm ci failed in $part"
  done
  write_config
  local out rc=0
  out=$( (cd "$clone" && scripts/ticket.sh claim next "$agent") 2>&1) || rc=$?
  printf '%s\n' "$out"
  case $rc in
    0) ;;
    3) log "no free ticket"; exit 0 ;;
    5) stop_for_help "$(git_c symbolic-ref --short HEAD)" "$(reason_file "$out")" ;;
    *) fail "the claim failed (exit $rc)" ;;
  esac
  ticket=$(git_c symbolic-ref --short HEAD)
  log "claimed $ticket"
  # From here until the push, nothing needs the token: the agent and the checks run without it.
  drop_token

  local try=1 prompt=$run/prompt.md failed=$run/failed.out last_pr=$run/last-pr.md rc
  fill "$prompts/build.md" "$prompt" TICKET "$ticket"
  while :; do
    rc=0
    # Filled again for every try: the filled copy is in a folder the agent could write.
    fill "$prompts/settings.json" "$run/settings.json" APP_CONFIG "$config" GH_CONFIG "$gh_config" SSH "$ssh_dir"
    run_agent "$try" "$prompt" || rc=$?
    write_config
    take_agent_files
    local line
    if [ "$rc" -ne 0 ] && line=$(limit_line "$run/agent-$try.out"); then
      stop_for_help "$ticket" "$(reason_file "Claude's usage limit was reached during try $try of $TRIES:
$line
The work so far is on this branch.")"
    fi
    if [ -s "$agent_files/stop.md" ]; then
      cp "$agent_files/stop.md" "$run/stop.md"
      stop_for_help "$ticket" "$run/stop.md"
    fi
    if [ "$rc" -ne 0 ]; then
      { echo "The agent exited with $rc$( [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ] && echo ", after its time limit ($AGENT_TIME)")."; tail -n "$OUTPUT_LINES" "$run/agent-$try.out"; } >"$failed"
    elif checks "$failed"; then
      break
    fi
    tail -n "$OUTPUT_LINES" "$failed" >"$failed.tail"
    mv "$failed.tail" "$failed"
    if [ "$try" -ge "$TRIES" ]; then
      stop_for_help "$ticket" "$(reason_file "The checks still fail after $TRIES tries.")" "$failed"
    fi
    if [ -f "$agent_files/pr.md" ]; then cp "$agent_files/pr.md" "$last_pr"; else echo "(missing)" >"$last_pr"; fi
    try=$((try + 1))
    fill "$prompts/fix-checks.md" "$prompt" TICKET "$ticket" TRY "$try" OUTPUT "@$failed" PR_MD "@$last_pr"
  done

  log "the checks pass: pushing $ticket"
  write_config
  new_token
  local push_out
  if ! push_out=$(push_branch "$ticket"); then
    printf '%s\n' "$push_out"
    if grep -qi 'workflow' <<<"$push_out"; then
      stop_for_help "$ticket" "$(reason_file "This ticket changes a workflow, which the runner's App can't push.")" "" refused
    fi
    fail "the push failed"
  fi
  first_line "$agent_files/pr.md" >"$run/pr-title.txt"
  tail -n +2 "$agent_files/pr.md" >"$run/pr-body.txt"
  open_pr "$ticket" "$run/pr-title.txt" "$run/pr-body.txt" false "$LABEL_RUN"
}

# ---- Main ----------------------------------------------------------------------------------

if [ "${1:-}" = check ]; then
  setup_checks
  exit $?
fi
[ $# -eq 0 ] || { echo "usage: scripts/agent-run.sh [check]" >&2; exit 1; }

stamp=$(date -u +%Y-%m-%dT%H-%M-%SZ)-$$
mkdir -p "$state/logs"
log_file=$state/logs/$stamp.log
exec > >(tee -a "$log_file") 2>&1
# Keep the newest logs only.
ls -1 "$state/logs" | sort | head -n -"$KEEP_LOGS" | while read -r f; do rm -f "$state/logs/$f"; done
run=$state/runs/$stamp
mkdir -p "$run"
agent_files=$run/agent-files

if [ -z "${XDG_RUNTIME_DIR:-}" ]; then
  fail "XDG_RUNTIME_DIR isn't set. Run this from a login session (or a systemd user service), which sets it."
fi
exec 9>"$XDG_RUNTIME_DIR/jd-cookie-agent.lock" ||
  fail "couldn't open the lock file $XDG_RUNTIME_DIR/jd-cookie-agent.lock. Run this from a login session."
if ! flock -n 9; then
  log "another run holds the lock: exiting"
  exit 0
fi

log "checking the setup"
setup_checks || fail "the setup check failed: see above, or run scripts/agent-run.sh check"

id=$(head -c 12 "$machine_id_file") || fail "couldn't read $machine_id_file"
agent=runner-$id
log "agent name: $agent"

new_token
bot_id=$(gh_api "users/$BOT_LOGIN" --jq .id) || fail "couldn't look up $BOT_LOGIN"
export GIT_AUTHOR_NAME=$BOT_LOGIN GIT_COMMITTER_NAME=$BOT_LOGIN
export GIT_AUTHOR_EMAIL="$bot_id+$BOT_LOGIN@users.noreply.github.com" GIT_COMMITTER_EMAIL="$bot_id+$BOT_LOGIN@users.noreply.github.com"

ensure_clone
find_work
build
log "done"
