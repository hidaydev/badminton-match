#!/bin/sh
# Create the local bm2 roles and databases. Safe to run repeatedly.
set -eu

REPO_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
ENV_FILE=${MAJADU_DEV_ENV:-"$REPO_ROOT/.env.local"}
ADMIN_DSN=${MAJADU_PG_ADMIN_DSN:-postgres}

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

command -v psql >/dev/null 2>&1 || fail "psql not found"

read_var() {
  [ -f "$ENV_FILE" ] || return 0
  sed -n "s/^$1=//p" "$ENV_FILE" | tail -n 1
}

ensure_var() {
  name=$1
  value=$(read_var "$name")
  if [ -z "$value" ]; then
    value=$(openssl rand -hex 16)
    umask 077
    printf '%s=%s\n' "$name" "$value" >> "$ENV_FILE"
  fi
  printf '%s' "$value"
}

OWNER_PW=$(ensure_var BM2_OWNER_PASSWORD)
APP_PW=$(ensure_var BM2_APP_PASSWORD)
ETL_PW=$(ensure_var BM2_ETL_PASSWORD)

psql -v ON_ERROR_STOP=1 -d "$ADMIN_DSN" \
  -v owner_pw="$OWNER_PW" -v app_pw="$APP_PW" -v etl_pw="$ETL_PW" <<'SQL'
SELECT format('CREATE ROLE bm2_owner LOGIN PASSWORD %L', :'owner_pw')
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'bm2_owner') \gexec
SELECT format('CREATE ROLE bm2_app LOGIN PASSWORD %L', :'app_pw')
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'bm2_app') \gexec
SELECT format('CREATE ROLE bm2_etl LOGIN PASSWORD %L', :'etl_pw')
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'bm2_etl') \gexec

ALTER ROLE bm2_owner WITH LOGIN PASSWORD :'owner_pw';
ALTER ROLE bm2_app WITH LOGIN PASSWORD :'app_pw';
ALTER ROLE bm2_etl WITH LOGIN PASSWORD :'etl_pw';

SELECT 'CREATE DATABASE bm2_dev OWNER bm2_owner'
WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = 'bm2_dev') \gexec
SELECT 'CREATE DATABASE bm2_template OWNER bm2_owner'
WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = 'bm2_template') \gexec
SQL

# `\connect <db>` keeps the host, port and user of the admin connection, so this
# works against a local socket and against a container exposed over TCP alike.
# Passing the bare database name to -d would fall back to the local socket and
# fail on a host where PostgreSQL only listens on the network.
for db in bm2_dev bm2_template; do
  psql -v ON_ERROR_STOP=1 -d "$ADMIN_DSN" -v db="$db" \
    -c "\\connect $db" -f "$REPO_ROOT/ops/dev/roles.sql" >/dev/null
done

psql -v ON_ERROR_STOP=1 -d "$ADMIN_DSN" -c \
  "ALTER DATABASE bm2_template IS_TEMPLATE true" >/dev/null

printf 'dev database ready: bm2_dev, bm2_template (template), roles bm2_owner/bm2_app/bm2_etl\n'
