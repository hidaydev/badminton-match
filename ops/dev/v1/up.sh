#!/bin/sh
# Create a local v1 database from the captured schema plus synthetic data.
# Safe to run repeatedly: the database is recreated from scratch.
set -eu

REPO_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
ADMIN_DSN=${MAJADU_PG_ADMIN_DSN:-postgres}
DB=${MAJADU_V1_DB:-bm_v1_dev}

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

case "$DB" in
  bm|postgres|template*)
    fail "refusing to recreate $DB"
    ;;
esac
printf '%s' "$DB" | grep -Eq '^[a-z0-9_]{1,40}$' || fail "invalid database name: $DB"

command -v psql >/dev/null 2>&1 || fail "psql not found"
[ -f "$REPO_ROOT/ops/dev/v1/schema.sql" ] || fail "missing ops/dev/v1/schema.sql"

psql -v ON_ERROR_STOP=1 -d "$ADMIN_DSN" \
  -c "DROP DATABASE IF EXISTS $DB WITH (FORCE)" >/dev/null
psql -v ON_ERROR_STOP=1 -d "$ADMIN_DSN" -c "CREATE DATABASE $DB" >/dev/null

psql -v ON_ERROR_STOP=1 -q -d "$DB" -f "$REPO_ROOT/ops/dev/v1/schema.sql" >/dev/null
psql -v ON_ERROR_STOP=1 -q -d "$DB" -f "$REPO_ROOT/ops/dev/v1/seed.sql" >/dev/null

players=$(psql -d "$DB" -tAc "select count(*) from bm.players")
sessions=$(psql -d "$DB" -tAc "select count(*) from bm.sessions")
printf 'v1 database ready: %s (players=%s sessions=%s)\n' "$DB" "$players" "$sessions"
printf 'run v1 against it with:\n'
printf '  (cd apps/api && DATABASE_URL=postgresql://%s@127.0.0.1:5432/%s MAJADU_DB_SCHEMA=bm MAJADU_ENV=dev PORT=8091 go run ./cmd/server)\n' \
  "$(whoami)" "$DB"
