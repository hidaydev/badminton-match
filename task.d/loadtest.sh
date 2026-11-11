#!/bin/sh
# Run the committed load test against a live endpoint or a disposable local one.
#
#   ./task loadtest --http https://api.qouver.com/majadu/readyz \
#     --requests 10000 --concurrency 50
#   ./task loadtest --local --requests 2000 --concurrency 20 --out report.json
#
# The record of the run is what fills the measured column in the capacity
# statement (docs/ops/operations.md). The live form needs a reachable API and,
# for the watcher half, a file of single-use watcher URLs.
#
# `--local` is the QA-17 form: it creates its own database, migrates and seeds
# it, builds and boots the API against it, runs the harness with the process id
# so the report carries RSS, and drops the database on the way out. One command,
# no VPS, no shared database, nothing left behind. It reports the same JSON as
# the live form: p50, p95, p99, failures and the RSS peak of the process under
# load.
set -eu
. "$(dirname "$0")/lib.sh"

require_cmd node

local=0
keep=0
has_http=0
db=""
port=""
out=""
args_file=$(mktemp "${TMPDIR:-/tmp}/majadu-loadtest-args.XXXXXX")

while [ "$#" -gt 0 ]; do
  case "$1" in
    --local) local=1 ;;
    --keep) keep=1 ;;
    --db)
      [ "$#" -ge 2 ] || fail "--db needs a database name"
      db=$2
      shift
      ;;
    --port)
      [ "$#" -ge 2 ] || fail "--port needs a number"
      port=$2
      shift
      ;;
    --out)
      [ "$#" -ge 2 ] || fail "--out needs a path"
      out=$2
      shift
      ;;
    --http) has_http=1 ;;
    -h|--help)
      cat <<'EOF'
Usage: ./task loadtest [--local] [options] [harness flags]

  --local        create, migrate, seed and drop a disposable local database and
                 run the load against an API booted on it (QA-17)
  --keep         with --local: leave the database in place for inspection
  --db <name>    with --local: database name (default bm2_load_test)
  --port <n>     with --local: port the local API listens on (default 18090)
  --out <path>   write the JSON report to this path as well as stdout

Every other flag goes to ops/scripts/loadtest.mjs unchanged: --http, --requests,
--concurrency, --ws-file, --hold-ms, --timeout-ms.
EOF
      exit 0
      ;;
    *) printf '%s\n' "$1" >>"$args_file" ;;
  esac
  shift
done

# Rebuild the argument list one argument at a time, so a path with a space
# survives the detour through the temp file.
set --
while IFS= read -r _arg; do
  set -- "$@" "$_arg"
done <"$args_file"
rm -f "$args_file"

if [ "$local" -eq 0 ]; then
  exec node "$REPO_ROOT/ops/scripts/loadtest.mjs" "$@"
fi

require_cmd psql
require_cmd curl
require_cmd nim

DB=${db:-${MAJADU_LOAD_DB:-bm2_load_test}}
PORT=${port:-${MAJADU_LOAD_PORT:-18090}}
require_database_name "$DB" "load database"

ADMIN_DSN=${MAJADU_PG_ADMIN_DSN:-"postgresql://$(whoami)@127.0.0.1:5432/postgres"}
DSN=$(dsn_with_database "$ADMIN_DSN" "$DB")

load_dir="$REPO_ROOT/.cache/$WORKTREE/load"
mkdir -p "$load_dir"
api_log="$load_dir/api.log"

# The migrations grant to the application roles, so a cluster that never ran
# `./task dev-db` cannot take them. pg-up.sh is idempotent and its password file
# is kept inside the cache, never the checkout.
if [ "$(psql -v ON_ERROR_STOP=1 -At -d "$ADMIN_DSN" \
  -c "select 1 from pg_roles where rolname = 'bm2_app'" 2>/dev/null || true)" != "1" ]; then
  mkdir -p "$load_dir/dev"
  MAJADU_PG_ADMIN_DSN=$ADMIN_DSN MAJADU_DEV_ENV="$load_dir/dev/dev.env" \
    sh "$REPO_ROOT/ops/dev/pg-up.sh" >/dev/null ||
    fail "cannot create the bm2 roles; is PostgreSQL running on 127.0.0.1:5432?"
fi

API_PID=""
cleanup() {
  if [ -n "$API_PID" ]; then
    kill "$API_PID" 2>/dev/null || true
    wait "$API_PID" 2>/dev/null || true
  fi
  if [ "$keep" -eq 0 ]; then
    psql -v ON_ERROR_STOP=1 -q -d "$ADMIN_DSN" \
      -c "drop database if exists $DB with (force)" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT INT TERM

psql -v ON_ERROR_STOP=1 -q -d "$ADMIN_DSN" \
  -c "drop database if exists $DB with (force)" ||
  fail "cannot drop a previous $DB"
psql -v ON_ERROR_STOP=1 -q -d "$ADMIN_DSN" -c "create database $DB" ||
  fail "cannot create $DB"

dbtools=$(ensure_dbtools)
MAJADU_PG_DSN=$DSN "$dbtools" migrate --dir "$REPO_ROOT/db/migrations" >/dev/null ||
  fail "cannot migrate $DB"
MAJADU_PG_DSN=$DSN "$dbtools" seed --dir "$REPO_ROOT/db/seeds" >/dev/null ||
  fail "cannot seed $DB"

sh "$REPO_ROOT/task.d/build.sh" >/dev/null
api="$REPO_ROOT/.cache/$WORKTREE/bin/majadu-api"

# The OIDC endpoints point at a closed port on purpose: this run measures the
# HTTP path, and a stub that never answers cannot be mistaken for capacity.
export MAJADU_PG_DSN=$DSN
export MAJADU_PORT=$PORT
export MAJADU_DRAIN_MS=0
export SHARE_CODE_KEYS=${SHARE_CODE_KEYS:-'{"1":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="}'}
export SHARE_CODE_ACTIVE_KEY_ID=${SHARE_CODE_ACTIVE_KEY_ID:-1}
export MAJADU_BOOTSTRAP_OWNER_EMAIL=${MAJADU_BOOTSTRAP_OWNER_EMAIL:-load@example.invalid}
export OIDC_AUTHORIZE_URL="http://127.0.0.1:9/authorize"
export OIDC_TOKEN_URL="http://127.0.0.1:9/token"
export OIDC_JWKS_URL="http://127.0.0.1:9/jwks"
export OIDC_ISSUER="http://127.0.0.1:9"
export OIDC_CLIENT_ID=majadu-load
export OIDC_REDIRECT_URI="http://127.0.0.1:$PORT/auth/callback"

"$api" >"$api_log" 2>&1 &
API_PID=$!
ready=0
for _ in $(seq 1 150); do
  if curl -fsS --max-time 1 "http://127.0.0.1:$PORT/healthz" >/dev/null 2>&1; then
    ready=1
    break
  fi
  sleep 0.2
done
if [ "$ready" -ne 1 ]; then
  tail -20 "$api_log" >&2 || true
  fail "the API did not answer on 127.0.0.1:$PORT; log: $api_log"
fi
printf 'loadtest: target http://127.0.0.1:%s on %s (pid %s)\n' "$PORT" "$DB" "$API_PID"

report="$load_dir/report.json"
if [ "$has_http" -eq 0 ]; then
  set -- "$@" --http "http://127.0.0.1:$PORT/readyz"
fi
code=0
node "$REPO_ROOT/ops/scripts/loadtest.mjs" --pid "$API_PID" "$@" >"$report" || code=$?
cat "$report"
if [ -n "$out" ]; then
  cp "$report" "$out"
  printf 'loadtest: report copied to %s\n' "$out"
fi
if [ "$keep" -eq 0 ]; then
  printf 'loadtest: dropping %s\n' "$DB"
fi
exit "$code"
