#!/bin/sh
# T-072: browser regression against a real API, a real database and the OIDC
# stub. Three servers, one disposable database, then Playwright.
#
#   ./task e2e                    # a11y + visual + compat
#   ./task e2e --update-snapshots # rewrite the visual baseline
set -eu

. "$(dirname "$0")/lib.sh"

require_cmd curl
require_cmd node
require_cmd pnpm
require_cmd psql

API_PORT=${MAJADU_E2E_API_PORT:-18093}
STUB_PORT=${MAJADU_E2E_STUB_PORT:-19081}
# 5173 is the seeded `security.allowed_origins` entry; the preview must own it.
WEB_PORT=${MAJADU_E2E_WEB_PORT:-5173}
DB=${MAJADU_E2E_DB:-bm2_e2e}
STUB_EMAIL=stub@example.com

sh "$REPO_ROOT/ops/dev/reset.sh" e2e >/dev/null

bin_dir="$REPO_ROOT/.cache/$WORKTREE/bin"
mkdir -p "$bin_dir"
nim_build -o:"$bin_dir/dbtools" "$REPO_ROOT/tools/dbtools/main.nim"
nim_build -o:"$bin_dir/oidc-stub" "$REPO_ROOT/tools/oidc-stub/main.nim"
sh "$REPO_ROOT/task.d/build.sh" >/dev/null

export MAJADU_PG_DSN="${MAJADU_E2E_DSN:-postgresql://$(whoami)@127.0.0.1:5432/$DB}"
"$bin_dir/dbtools" migrate --dir "$REPO_ROOT/db/migrations" >/dev/null
"$bin_dir/dbtools" seed --dir "$REPO_ROOT/db/seeds" >/dev/null

OIDC_STUB_PORT=$STUB_PORT OIDC_STUB_ISSUER=http://127.0.0.1:$STUB_PORT \
  OIDC_STUB_CLIENT_ID=majadu-e2e "$bin_dir/oidc-stub" >/tmp/e2e-stub.log 2>&1 &
STUB_PID=$!

export MAJADU_PORT=$API_PORT
export MAJADU_DRAIN_MS=0
export SHARE_CODE_KEYS='{"1":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="}'
export SHARE_CODE_ACTIVE_KEY_ID=1
export OIDC_AUTHORIZE_URL=http://127.0.0.1:$STUB_PORT/authorize
export OIDC_TOKEN_URL=http://127.0.0.1:$STUB_PORT/token
export OIDC_JWKS_URL=http://127.0.0.1:$STUB_PORT/jwks
export OIDC_ISSUER=http://127.0.0.1:$STUB_PORT
export OIDC_CLIENT_ID=majadu-e2e
export OIDC_REDIRECT_URI=http://127.0.0.1:$WEB_PORT/api/auth/callback
export MAJADU_BOOTSTRAP_OWNER_EMAIL=$STUB_EMAIL

"$bin_dir/majadu-api" >/tmp/e2e-api.log 2>&1 &
API_PID=$!

cleanup() {
  kill "$API_PID" "$STUB_PID" "${WEB_PID:-}" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

ready=0
for _ in $(seq 1 100); do
  if curl -fsS --max-time 1 "http://127.0.0.1:$API_PORT/healthz" >/dev/null 2>&1; then
    ready=1
    break
  fi
  sleep 0.2
done
# Without this the suite runs against a dead API and Playwright reports a
# timeout per spec instead of one actionable line.
[ "$ready" = 1 ] || fail "API did not answer /healthz on :$API_PORT (log: /tmp/e2e-api.log)"

pnpm --filter badminton-pair-tmp build >/dev/null

E2E_API_PROXY="http://127.0.0.1:$API_PORT" \
  pnpm --filter badminton-pair-tmp exec vite preview --host 127.0.0.1 --port "$WEB_PORT" \
  >/tmp/e2e-web.log 2>&1 &
WEB_PID=$!

ready=0
for _ in $(seq 1 100); do
  if curl -fsS --max-time 1 "http://127.0.0.1:$WEB_PORT/" >/dev/null 2>&1; then
    ready=1
    break
  fi
  sleep 0.2
done
[ "$ready" = 1 ] || fail "web preview did not answer on :$WEB_PORT (log: /tmp/e2e-web.log)"

E2E_BASE_URL="http://127.0.0.1:$WEB_PORT" \
  pnpm exec playwright test --config "$REPO_ROOT/apps/web/playwright.config.ts" "$@"
