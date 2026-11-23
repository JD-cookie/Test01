#!/bin/sh
# Makes an installation token for the runner's GitHub App, JD-cookie-Agent.
#
#   scripts/agent-token.sh 3>"$file"     # the token goes to file descriptor 3, and only there
#
# The token lasts an hour and reaches only this repo. It's printed to file descriptor 3, never to
# stdout, a log, or a command line, so the caller decides where it goes (the runner reads it into
# a variable: token=$(scripts/agent-token.sh 3>&1 1>&2)). Messages go to stderr.
#
# Steps (see docs/features/0007-agent-runner.md, "The App's token"):
#   1. A JWT, signed with the App's private key with openssl: valid from a minute ago for ten minutes.
#   2. GET /repos/<owner>/<repo>/installation, with the JWT: the installation's id.
#   3. POST /app/installations/<id>/access_tokens, with the JWT, limited to this repo: the token.
# curl reads the Authorization header from a file in a private temporary folder, so neither the
# JWT nor the token is ever on a command line, where ps shows it.
#
# Files: ${XDG_CONFIG_HOME:-$HOME/.config}/jd-cookie-agent/app.pem (mode 600) and app.env
# (APP_CLIENT_ID=…, not secret). For tests only, AGENT_RUN_GITHUB_API replaces the API's base URL.
#
# Exit codes: 0 the token was written to fd 3, 1 any step failed (the message says which).
set -eu

owner=JD-cookie
repo=Test01
api=${AGENT_RUN_GITHUB_API:-https://api.github.com}
config=${XDG_CONFIG_HOME:-$HOME/.config}/jd-cookie-agent
key=$config/app.pem

die() { echo "agent-token: $*" >&2; exit 1; }

# fd 3 must be open: otherwise the token would have nowhere to go.
{ true >&3; } 2>/dev/null || die "file descriptor 3 isn't open: run it as  token=\$(scripts/agent-token.sh 3>&1 1>&2)"

[ -f "$key" ] || die "the App's private key is missing: $key"
mode=$(stat -c %a "$key") || die "couldn't read the mode of $key"
[ "$mode" = 600 ] || die "$key has mode $mode: it must be 600, readable only by you (chmod 600 $key)"
[ -f "$config/app.env" ] || die "missing $config/app.env, with APP_CLIENT_ID=<the App's client id>"
client_id=$(sed -n 's/^APP_CLIENT_ID=//p' "$config/app.env" | tail -1)
case $client_id in
  '' | *[!A-Za-z0-9._-]*) die "$config/app.env must set APP_CLIENT_ID to the App's client id" ;;
esac

tmp=$(mktemp -d) || die "couldn't make a temporary folder"
chmod 700 "$tmp"
trap 'rm -rf "$tmp"' EXIT INT TERM

b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }

now=$(date +%s) || die "couldn't read the clock"
header=$(printf '%s' '{"alg":"RS256","typ":"JWT"}' | b64url)
payload=$(printf '{"iat":%s,"exp":%s,"iss":"%s"}' "$((now - 60))" "$((now + 540))" "$client_id" | b64url)
signature=$(printf '%s.%s' "$header" "$payload" | openssl dgst -sha256 -sign "$key" | b64url) ||
  die "couldn't sign the JWT with $key"
[ -n "$signature" ] || die "couldn't sign the JWT with $key"
{
  printf 'Authorization: Bearer %s.%s.%s\n' "$header" "$payload" "$signature"
  printf 'Accept: application/vnd.github+json\n'
  printf 'X-GitHub-Api-Version: 2022-11-28\n'
} >"$tmp/headers"

# Calls the API: $1 is the step's name (for messages), $2 the method, $3 the path, $4 an optional
# body. The response body is left in $tmp/body. Fails with the HTTP status unless it's 2xx.
call() {
  set -- "$1" "$2" "$3" "${4:-}"
  if [ -n "$4" ]; then
    printf '%s' "$4" >"$tmp/request"
    status=$(curl -sS -o "$tmp/body" -w '%{http_code}' -X "$2" -H @"$tmp/headers" \
      -H 'Content-Type: application/json' --data-binary @"$tmp/request" "$api$3") ||
      die "$1: the request to $3 failed"
  else
    status=$(curl -sS -o "$tmp/body" -w '%{http_code}' -X "$2" -H @"$tmp/headers" "$api$3") ||
      die "$1: the request to $3 failed"
  fi
  case $status in
    2??) ;;
    *) die "$1: GitHub answered HTTP $status for $2 $3" ;;
  esac
}

# Prints one field of the JSON in $tmp/body, or fails. node is one of the runner's tools.
field() {
  node -e '
    const v = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"))[process.argv[2]];
    if (v === undefined || v === null || v === "") process.exit(1);
    process.stdout.write(String(v));
  ' "$tmp/body" "$1"
}

call "finding the App's installation" GET "/repos/$owner/$repo/installation"
installation=$(field id) || die "finding the App's installation: the answer had no id"
case $installation in *[!0-9]*) die "finding the App's installation: the id isn't a number" ;; esac

call "making the token" POST "/app/installations/$installation/access_tokens" "{\"repositories\":[\"$repo\"]}"
token=$(field token) || die "making the token: the answer had no token"

# The token is opaque: GitHub's start with ghs_, are about 520 characters, and contain dots.
# Nothing here checks its length or shape.
printf '%s' "$token" >&3
