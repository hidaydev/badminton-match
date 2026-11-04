#!/bin/sh
# Local development: database, OIDC stub, API. The frontend runs separately
# with `pnpm dev`, because Vite already hot-reloads and this script must not
# pretend the Nim API can.
#
#   ./task dev            # build and run the API against bm2_dev
#   ./task dev --watch    # rebuild and restart when a .nim file changes
#
# Override with MAJADU_DEV_DSN, MAJADU_DEV_PORT, MAJADU_DEV_STUB_PORT.
set -eu

. "$(dirname "$0")/lib.sh"

require_cmd curl
require_cmd nim
require_cmd psql

DSN=${MAJADU_DEV_DSN:-"postgresql://$(whoami)@127.0.0.1:5432/bm2_dev"}
PORT=${MAJADU_DEV_PORT:-8080}
STUB_PORT=${MAJADU_DEV_STUB_PORT:-19090}
WATCH=0
[ "${1:-}" = "--watch" ] && WATCH=1

bin_dir="$REPO_ROOT/.cache/$WORKTREE/bin"
mkdir -p "$bin_dir"

# Same public test key as the parity corpus; share links made yesterday in a
# dev database keep decoding after a restart.
export SHARE_CODE_KEYS='{"1":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="}'
export SHARE_CODE_ACTIVE_KEY_ID=1
export MAJADU_PG_DSN="$DSN"
export MAJADU_PORT="$PORT"
export MAJADU_DRAIN_MS=0
export MAJADU_BOOTSTRAP_OWNER_EMAIL=${MAJADU_DEV_OWNER_EMAIL:-stub@example.com}
export OIDC_AUTHORIZE_URL="http://127.0.0.1:$STUB_PORT/authorize"
export OIDC_TOKEN_URL="http://127.0.0.1:$STUB_PORT/token"
export OIDC_JWKS_URL="http://127.0.0.1:$STUB_PORT/jwks"
export OIDC_ISSUER="http://127.0.0.1:$STUB_PORT"
export OIDC_CLIENT_ID=majadu-dev
export OIDC_REDIRECT_URI="http://localhost:5173/api/auth/callback"

if ! psql "$DSN" -Atc "select 1" >/dev/null 2>&1; then
  fail "cannot reach $DSN; run ./task dev-db first"
fi

nim_build -o:"$bin_dir/dbtools" "$REPO_ROOT/tools/dbtools/main.nim"
nim_build -o:"$bin_dir/oidc-stub" "$REPO_ROOT/tools/oidc-stub/main.nim"

"$bin_dir/dbtools" migrate --dir "$REPO_ROOT/db/migrations" >/dev/null
"$bin_dir/dbtools" seed --dir "$REPO_ROOT/db/seeds" >/dev/null

OIDC_STUB_PORT=$STUB_PORT OIDC_STUB_ISSUER="http://127.0.0.1:$STUB_PORT" \
  OIDC_STUB_CLIENT_ID=majadu-dev "$bin_dir/oidc-stub" >/tmp/majadu-dev-stub.log 2>&1 &
STUB_PID=$!
API_PID=""

cleanup() {
  [ -n "$API_PID" ] && kill "$API_PID" 2>/dev/null || true
  kill "$STUB_PID" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

build_api() {
  nim_build -o:"$bin_dir/majadu-api" "$(api_entrypoint)" >/dev/null
}

start_api() {
  "$bin_dir/majadu-api" >>/tmp/majadu-dev-api.log 2>&1 &
  API_PID=$!
  for _ in $(seq 1 100); do
    if curl -fsS --max-time 1 "http://127.0.0.1:$PORT/healthz" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.1
  done
  fail "the API did not answer on 127.0.0.1:$PORT; see /tmp/majadu-dev-api.log"
}

sources_hash() {
  find "$REPO_ROOT/apps/api/src" "$REPO_ROOT/modules" "$REPO_ROOT/shared" \
    -name '*.nim' -type f -exec shasum -a 256 {} + | LC_ALL=C sort | shasum -a 256
}

build_api
start_api

printf 'dev: API      http://127.0.0.1:%s  (log /tmp/majadu-dev-api.log)\n' "$PORT"
printf 'dev: OIDC     http://127.0.0.1:%s  (log /tmp/majadu-dev-stub.log)\n' "$STUB_PORT"
printf 'dev: frontend pnpm dev → http://localhost:5173 (hot reload)\n'
printf 'dev: first login is %s, the platform owner\n' "$MAJADU_BOOTSTRAP_OWNER_EMAIL"

if [ "$WATCH" = "1" ]; then
  printf 'dev: watching .nim sources; Ctrl-C to stop\n'
  current=$(sources_hash)
  while :; do
    sleep 1
    next=$(sources_hash)
    [ "$next" = "$current" ] && continue
    current=$next
    printf 'dev: rebuild\n'
    kill "$API_PID" 2>/dev/null || true
    wait "$API_PID" 2>/dev/null || true
    if build_api; then
      start_api
      printf 'dev: API restarted\n'
    else
      printf 'dev: build failed, still watching\n' >&2
    fi
  done
else
  wait "$API_PID"
fi
