#!/bin/sh
# R0 walking skeleton: real binary, local database, OIDC stub.
#
# Proves the frozen contract is actually served: log in, create a community,
# create a session, issue a share link, then read the public endpoints.
set -eu

. "$(dirname "$0")/lib.sh"

require_cmd curl
require_cmd python3
require_cmd psql

PORT=${MAJADU_DEMO_PORT:-18080}
STUB_PORT=${MAJADU_DEMO_STUB_PORT:-19080}
DB=${MAJADU_DEMO_DB:-bm2_r0}
OWNER_EMAIL=${MAJADU_DEMO_OWNER_EMAIL:-owner@example.com}

json() {
  python3 -c "import sys, json; print(json.loads(sys.stdin.read())$1)"
}

fail_step() {
  printf 'r0-demo: FAIL %s\n' "$*" >&2
  exit 1
}

sh "$REPO_ROOT/ops/dev/reset.sh" r0 >/dev/null

bin_dir="$REPO_ROOT/.cache/$WORKTREE/bin"
mkdir -p "$bin_dir"
nim c $CHECK_FLAGS --nimcache:"$NIMCACHE_CHECK" -o:"$bin_dir/dbtools" \
  "$REPO_ROOT/tools/dbtools/main.nim"
nim c $CHECK_FLAGS --nimcache:"$NIMCACHE_CHECK" -o:"$bin_dir/oidc-stub" \
  "$REPO_ROOT/tools/oidc-stub/main.nim"
sh "$REPO_ROOT/task.d/build.sh" >/dev/null

export MAJADU_PG_DSN="postgresql://sachiel@127.0.0.1:5432/$DB"
"$bin_dir/dbtools" migrate --dir "$REPO_ROOT/db/migrations" >/dev/null
"$bin_dir/dbtools" seed --dir "$REPO_ROOT/db/seeds" >/dev/null

OIDC_STUB_PORT=$STUB_PORT OIDC_STUB_ISSUER=http://127.0.0.1:$STUB_PORT \
  OIDC_STUB_CLIENT_ID=majadu-dev "$bin_dir/oidc-stub" >/tmp/r0-stub.log 2>&1 &
STUB_PID=$!

export MAJADU_PORT=$PORT
export MAJADU_DRAIN_MS=0
export SHARE_CODE_KEYS='{"1":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="}'
export SHARE_CODE_ACTIVE_KEY_ID=1
export OIDC_AUTHORIZE_URL=http://127.0.0.1:$STUB_PORT/authorize
export OIDC_TOKEN_URL=http://127.0.0.1:$STUB_PORT/token
export OIDC_JWKS_URL=http://127.0.0.1:$STUB_PORT/jwks
export OIDC_ISSUER=http://127.0.0.1:$STUB_PORT
export OIDC_CLIENT_ID=majadu-dev
export OIDC_REDIRECT_URI=http://127.0.0.1:$PORT/auth/callback
export MAJADU_BOOTSTRAP_OWNER_EMAIL=$OWNER_EMAIL
export MAJADU_DEFAULT_TIMEZONE=Asia/Jakarta

"$bin_dir/majadu-api" >/tmp/r0-api.log 2>&1 &
API_PID=$!
JAR=/tmp/r0-demo-cookies.txt
rm -f "$JAR"

cleanup() {
  kill "$API_PID" "$STUB_PID" 2>/dev/null || true
}
trap cleanup EXIT INT TERM
sleep 1

base="http://127.0.0.1:$PORT"
[ "$(curl -s "$base/healthz")" = '{"status":"ok"}' ] || fail_step "healthz"
[ "$(curl -s -o /dev/null -w '%{http_code}' "$base/readyz")" = "200" ] || fail_step "readyz"

start=$(curl -s -X POST -H 'Content-Type: application/json' -d '{"returnTo":"/"}' \
  "$base/auth/start")
authorize=$(printf '%s' "$start" | json "['authorizeUrl']")
location=$(curl -s -o /dev/null -D - "$authorize&login_hint=$(printf '%s' "$OWNER_EMAIL" |
  python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.stdin.read().strip(), safe=""))')" |
  grep -i '^location:' | tr -d '\r' | cut -d' ' -f2)
[ -n "$location" ] || fail_step "authorize redirect"

curl -s -o /dev/null -c "$JAR" "$location" || fail_step "callback"
me=$(curl -s -b "$JAR" "$base/auth/me")
[ "$(printf '%s' "$me" | json "['platformOwner']")" = "True" ] || fail_step "auth/me"

community=$(curl -s -b "$JAR" -X POST -H 'Content-Type: application/json' \
  -d '{"slug":"demo-club","name":"Demo Club"}' "$base/communities")
[ "$(printf '%s' "$community" | json "['slug']")" = "demo-club" ] || fail_step "community"
[ "$(printf '%s' "$community" | json "['timezone']")" = "Asia/Jakarta" ] ||
  fail_step "community timezone default"

csrf=$(curl -s -o /dev/null -w '%{http_code}' -b "$JAR" -X POST \
  -H 'Origin: https://evil.example' -H 'Content-Type: application/json' \
  -d '{"slug":"csrf","name":"CSRF"}' "$base/communities")
[ "$csrf" = "403" ] || fail_step "foreign origin should be 403, got $csrf"

curl -s -D /tmp/r0-headers -o /dev/null "$base/healthz"
grep -qi '^X-Content-Type-Options: nosniff' /tmp/r0-headers || fail_step "security headers"
grep -qi '^Content-Security-Policy:' /tmp/r0-headers || fail_step "CSP header"

duplicate=$(curl -s -o /dev/null -w '%{http_code}' -b "$JAR" -X POST \
  -H 'Content-Type: application/json' -d '{"slug":"demo-club","name":"Again"}' \
  "$base/communities")
[ "$duplicate" = "409" ] || fail_step "duplicate slug should be 409, got $duplicate"

session=$(curl -s -b "$JAR" -X POST -H 'Content-Type: application/json' \
  -d '{"title":"Tuesday Night","date":"2026-11-03","startTime":"19:00"}' \
  "$base/c/demo-club/sessions")
session_id=$(printf '%s' "$session" | json "['id']")

share=$(curl -s -b "$JAR" -X POST "$base/c/demo-club/sessions/$session_id/share")
code=$(printf '%s' "$share" | json "['code']")
[ "${#code}" = "32" ] || fail_step "share code length"

shared=$(curl -s "$base/s/$code")
[ "$(printf '%s' "$shared" | json "['session']['id']")" = "$session_id" ] ||
  fail_step "shared session"
[ "$(curl -s -o /dev/null -w '%{http_code}' "$base/s/$code/rankings")" = "200" ] ||
  fail_step "shared rankings"
[ "$(curl -s -o /dev/null -w '%{http_code}' "$base/s/00000000000000000000000000000000")" = "404" ] ||
  fail_step "unknown share code"

redisplay=$(curl -s -b "$JAR" "$base/c/demo-club/sessions/$session_id/share")
[ "$(printf '%s' "$redisplay" | json "['code']")" = "$code" ] || fail_step "share re-display"

rotated=$(curl -s -b "$JAR" -X POST "$base/c/demo-club/sessions/$session_id/share")
[ "$(printf '%s' "$rotated" | json "['code']")" != "$code" ] || fail_step "share rotation"
[ "$(curl -s -o /dev/null -w '%{http_code}' "$base/s/$code")" = "404" ] ||
  fail_step "revoked share code must be 404"

sessions=$(curl -s -b "$JAR" "$base/auth/sessions")
[ "$(printf '%s' "$sessions" | python3 -c 'import sys,json;print(len(json.load(sys.stdin)["items"]))')" = "1" ] ||
  fail_step "auth/sessions list"
[ "$(curl -s -o /dev/null -w '%{http_code}' -b "$JAR" -X DELETE "$base/auth/sessions")" = "204" ] ||
  fail_step "auth/sessions revoke-all"

curl -s -o /dev/null -b "$JAR" -X POST "$base/auth/logout"
[ "$(curl -s -o /dev/null -w '%{http_code}' -b "$JAR" "$base/auth/me")" = "401" ] ||
  fail_step "logout"

printf 'r0-demo: ok (login, community, session, share, public read, rotation, logout)\n'
