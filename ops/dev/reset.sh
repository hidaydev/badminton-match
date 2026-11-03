#!/bin/sh
# Recreate one worker database from bm2_template.
set -eu

suffix=${1:-worker}
ADMIN_DSN=${MAJADU_PG_ADMIN_DSN:-postgres}
name="bm2_$suffix"

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

case "$suffix" in
  dev|template|"")
    fail "refusing to reset $name; use a worker suffix"
    ;;
esac

printf '%s' "$name" | grep -Eq '^bm2_[a-z0-9_]{1,40}$' ||
  fail "invalid worker name: $name (lowercase letters, digits, underscore)"

psql -v ON_ERROR_STOP=1 -d "$ADMIN_DSN" \
  -c "DROP DATABASE IF EXISTS $name WITH (FORCE)" >/dev/null
psql -v ON_ERROR_STOP=1 -d "$ADMIN_DSN" \
  -c "CREATE DATABASE $name TEMPLATE bm2_template OWNER bm2_owner" >/dev/null
psql -v ON_ERROR_STOP=1 -d "$ADMIN_DSN" \
  -c "GRANT CONNECT ON DATABASE $name TO bm2_app, bm2_etl" >/dev/null

printf 'worker database ready: %s\n' "$name"
