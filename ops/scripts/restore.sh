#!/usr/bin/env bash
# Restore a custom-format dump into a database.
#
#   ./ops/scripts/restore.sh --file backups/bm2-20261104-0300.dump --target bm2
#   ./ops/scripts/restore.sh --file dump --target bm_staging --recreate \
#     --dsn postgres://bm2_owner@qouver-postgres:5432/bm_staging --no-privileges
#
# Privileges are restored by default: a bm2 dump carries the bm2_app grants and
# default ACLs, and dropping them leaves the API unable to read its own schema.
# --no-privileges is for a staging copy of a v1 dump, whose grants name v1 roles.
#
# The target guard is an allow-list, not a deny-list: `bm`, `bm2`, `bm_staging`,
# anything starting with `bm2_`, and rehearsal targets starting with
# `bm_restore_`. `bm_staging` is on the list on purpose - the cutover itself
# restores the v1 dump there before the ETL runs, so a guard that only protected
# production would block the one step that needs it.
#
# `bm` and `bm2` additionally require --force: the first is the permanent
# archive, the second is live.
#
# The guard protects the database that is written, not the label: the database
# name in --dsn has to equal --target, and a mismatch is refused. Only the
# sslmode parameter may appear in a --dsn query string; libpq lets other keys
# (notably dbname) override the destination, so any other key, encoded or not,
# is refused before the lock is taken. The write also takes the same deploy lock
# deploy-vps.sh and cutover.sh use, so a restore cannot run while a deploy is
# swapping the release.
#
# cutover.sh passes MAJADU_CUTOVER_RESTORE_DSN here for the bm_staging restore.
# That role has to own bm_staging or have CREATEDB because --recreate drops and
# creates the database; it is not the ETL role, which may only write bm2.
set -euo pipefail

APP_DIR="${MAJADU_APP_DIR:-/srv/qouver/apps/majadu}"
LOCK_FILE="$APP_DIR/.deploy.lock"
PG_CONTAINER="${MAJADU_PG_CONTAINER:-qouver-postgres}"
USE_CONTAINER=0

FILE=""
TARGET=""
RECREATE=0
FORCE=0
NO_PRIVILEGES=0
DSN=""

usage() {
  sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --file) shift; FILE="${1:-}" ;;
    --target) shift; TARGET="${1:-}" ;;
    --dsn) shift; DSN="${1:-}" ;;
    --recreate) RECREATE=1 ;;
    --force) FORCE=1 ;;
    --no-privileges) NO_PRIVILEGES=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "restore: unknown argument $1" >&2; exit 2 ;;
  esac
  shift
done

[ -n "$FILE" ] || { echo "restore: --file is required" >&2; exit 2; }
[ -n "$TARGET" ] || { echo "restore: --target is required" >&2; exit 2; }
[ -f "$FILE" ] || { echo "restore: $FILE does not exist" >&2; exit 2; }

case "$TARGET" in
  bm|bm2|bm_staging|bm2_*|bm_restore_*) ;;
  *) echo "restore: refusing to write into '$TARGET'" >&2; exit 2 ;;
esac

if { [ "$TARGET" = "bm" ] || [ "$TARGET" = "bm2" ]; } && [ "$FORCE" -ne 1 ]; then
  echo "restore: '$TARGET' is production or archive; pass --force to write into it" >&2
  exit 2
fi

# libpq splits a URI-like DSN as scheme://userinfo@authority/path?query.
# Userinfo only exists before the first path slash, so an "@" in a query value
# is not a userinfo separator, and a "?" inside userinfo is literal text. When
# the text before the first slash carries "@", the authority is the userinfo
# plus the host up to the next "/" or "?"; otherwise it ends at the first "/"
# or "?". A "?" before any path is a query with no path, which libpq would feed
# to dbname, so this script refuses that shape instead of guessing where the
# write goes.
dsn_rest() {
  case "$1" in
    postgres://*|postgresql://*) printf '%s\n' "${1#*://}" ;;
    *) return 1 ;;
  esac
}

dsn_tail() {
  local rest pre at userinfo host authority
  rest=$(dsn_rest "$1") || return 1
  case "$rest" in
    */*) pre=${rest%%/*} ;;
    *) pre=$rest ;;
  esac
  case "$pre" in
    *@*)
      at=${rest#*@}
      case "$at" in
        *[/?]*) host=${at%%[/?]*} ;;
        *) host=$at ;;
      esac
      userinfo=${rest%%@*}@
      authority=$userinfo$host
      ;;
    *) authority=${rest%%[?/]*} ;;
  esac
  printf '%s\n' "${rest#"$authority"}"
}

dsn_authority() {
  local rest tail
  rest=$(dsn_rest "$1") || return 1
  tail=$(dsn_tail "$1") || return 1
  printf '%s\n' "${rest%"$tail"}"
}

dsn_path() {
  local tail pathq
  tail=$(dsn_tail "$1") || return 1
  case "$tail" in
    /*) pathq=${tail#/} ;;
    *) return 1 ;;
  esac
  printf '%s\n' "${pathq%%\?*}"
}

# The database is the path up to the query; the query starts only after it.
dsn_database() {
  local path
  path=$(dsn_path "$1") || return 1
  path=${path%%\?*}
  [ -n "$path" ] || return 1
  printf '%s\n' "$path"
}

if [ -z "$DSN" ]; then
  DSN="postgresql:///${TARGET}"
fi

DSN_DB=$(dsn_database "$DSN") || {
  echo "restore: cannot read a database name from --dsn '$DSN'" >&2
  exit 2
}
if [ "$DSN_DB" != "$TARGET" ]; then
  echo "restore: --target '$TARGET' does not match the database '$DSN_DB' in --dsn; refusing to write into '$DSN_DB'" >&2
  exit 2
fi

# libpq reads connection keywords from the URI query string, and `dbname` there
# overrides the path. Only sslmode cannot change where the write goes, so every
# other key is refused. Keys are decoded first so `%64bname` is caught, compared
# case-sensitively so `DbName` is refused too, and an undecodable key is an
# error rather than a pass.
url_decode_key() {
  local value=$1 out="" rest ch hex
  rest=$value
  while [ -n "$rest" ]; do
    ch=${rest%%\%*}
    if [ "$ch" = "$rest" ]; then
      out=$out$ch
      break
    fi
    out=$out$ch
    rest=${rest#*%}
    hex=${rest:0:2}
    case "$hex" in
      [0-9A-Fa-f][0-9A-Fa-f]) ;;
      *) return 1 ;;
    esac
    out=$out$(printf "\\$(printf '%03o' "$((16#$hex))")")
    rest=${rest:2}
  done
  printf '%s' "$out"
}

dsn_query() {
  local tail
  tail=$(dsn_tail "$1") || return 0
  dsn_path "$1" >/dev/null 2>&1 || return 0
  case "$tail" in
    *\?*) printf '%s\n' "${tail#*\?}" ;;
  esac
}

QUERY=$(dsn_query "$DSN")
case "$QUERY" in
  *';'*)
    echo "restore: --dsn query contains ';', which libpq reads as a conninfo separator; refusing" >&2
    exit 2
    ;;
esac
if [ -n "$QUERY" ]; then
  rest=$QUERY
  while [ -n "$rest" ]; do
    pair=${rest%%&*}
    if [ "$pair" = "$rest" ]; then
      rest=""
    else
      rest=${rest#*&}
    fi
    key=${pair%%=*}
    [ -n "$key" ] || {
      echo "restore: empty connection parameter in --dsn; refusing" >&2
      exit 2
    }
    decoded=$(url_decode_key "$key") || {
      echo "restore: cannot decode connection parameter '$key' in --dsn" >&2
      exit 2
    }
    [ "$decoded" = "sslmode" ] || {
      echo "restore: connection parameter '$decoded' in --dsn can change the destination; only sslmode is allowed" >&2
      exit 2
    }
  done
fi

# The documented host has no psql/pg_restore. When either is absent the client
# moves into the PostgreSQL container, the same way bootstrap-rc.sh runs; the
# dump stays on the host and is piped, because the container cannot see it.
for tool in pg_restore psql; do
  command -v "$tool" >/dev/null 2>&1 || USE_CONTAINER=1
done
if [ "$USE_CONTAINER" -eq 1 ]; then
  command -v podman >/dev/null 2>&1 ||
    { echo "restore: host has no psql/pg_restore and podman is not installed" >&2; exit 2; }
  podman container exists "$PG_CONTAINER" 2>/dev/null ||
    { echo "restore: host has no psql/pg_restore and container '$PG_CONTAINER' does not exist" >&2; exit 2; }
fi
command -v flock >/dev/null 2>&1 || { echo "restore: flock is required" >&2; exit 2; }
[ -d "$APP_DIR" ] || { echo "restore: $APP_DIR does not exist; cannot take the deploy lock" >&2; exit 2; }

# True when fd 9 already points at the deploy lock. cutover.sh holds that lock
# while it calls this script and bash hands the descriptor down, so opening a
# second description of the same file would block on our own parent. Compare the
# file identity, not the path, because /proc resolves symlinks.
file_identity() {
  stat -L -c '%d:%i' "$1" 2>/dev/null || stat -L -f '%i' "$1" 2>/dev/null || echo "?"
}

inherits_lock() {
  local lock_id fd_id
  [ -e /dev/fd/9 ] || return 1
  lock_id=$(file_identity "$LOCK_FILE")
  fd_id=$(file_identity /dev/fd/9)
  [ "$lock_id" != "?" ] && [ "$lock_id" = "$fd_id" ]
}

psql_cmd() {
  if [ "$USE_CONTAINER" -eq 1 ]; then
    podman exec -i "$PG_CONTAINER" psql "$@"
  else
    psql "$@"
  fi
}

pg_restore_list() {
  if [ "$USE_CONTAINER" -eq 1 ]; then
    podman exec -i "$PG_CONTAINER" pg_restore --list <"$1"
  else
    pg_restore --list "$1"
  fi
}

pg_restore_file() {
  # Privileges are kept by default: a bm2 dump without its ACLs restores into a
  # database the application cannot log into. A staging restore of a v1 dump
  # passes --no-privileges because those grants name v1 roles and the staging
  # copy is read-only.
  if [ "$NO_PRIVILEGES" -eq 1 ]; then
    if [ "$USE_CONTAINER" -eq 1 ]; then
      podman exec -i "$PG_CONTAINER" pg_restore --clean --if-exists \
        --no-owner --no-privileges --dbname "$DSN" <"$FILE"
    else
      pg_restore --clean --if-exists --no-owner --no-privileges \
        --dbname "$DSN" "$FILE"
    fi
  else
    if [ "$USE_CONTAINER" -eq 1 ]; then
      podman exec -i "$PG_CONTAINER" pg_restore --clean --if-exists \
        --no-owner --dbname "$DSN" <"$FILE"
    else
      pg_restore --clean --if-exists --no-owner --dbname "$DSN" "$FILE"
    fi
  fi
}

if ! inherits_lock; then
  exec 9>"$LOCK_FILE"
  if ! flock -w 900 9; then
    echo "restore: another deploy or cutover holds $LOCK_FILE; refusing to write into '$TARGET'" >&2
    exit 1
  fi
fi

if ! pg_restore_list "$FILE" >/dev/null 2>&1; then
  echo "restore: $FILE is not a readable custom-format dump" >&2
  exit 1
fi

# Derive the maintenance connection from the target DSN: same host, port and
# role, but the `postgres` database, because the target cannot be dropped from a
# connection to itself. A unix-socket DSN (`postgresql:///db`) carries no host,
# so --recreate refuses it instead of silently dropping a database on whatever
# server the local socket happens to point at.
maintenance_dsn() {
  local dsn=$1 scheme authority path query hostport host
  case "$dsn" in
    postgres://*) scheme="postgres" ;;
    postgresql://*) scheme="postgresql" ;;
    *) return 1 ;;
  esac
  authority=$(dsn_authority "$dsn") || return 1
  path=$(dsn_path "$dsn") || return 1
  query=$(dsn_query "$dsn")
  [ -n "$authority" ] || return 1
  [ -n "$path" ] || return 1
  case "$query" in
    "") ;;
    *) query="?$query" ;;
  esac
  hostport=${authority##*@}
  case "$hostport" in
    \[*\]:*) host=${hostport%]:*}"]" ;;
    \[*\]) host=$hostport ;;
    *:*) host=${hostport%%:*} ;;
    *) host=$hostport ;;
  esac
  [ -n "$host" ] || return 1
  printf '%s://%s/postgres%s\n' "$scheme" "$authority" "$query"
}

if [ "$RECREATE" -eq 1 ]; then
  MAINT_DSN=$(maintenance_dsn "$DSN") || {
    echo "restore: --recreate needs a host in --dsn; refusing to drop '$TARGET' on an unknown server" >&2
    echo "restore: pass --dsn postgres://<user>@<host>:<port>/<database>" >&2
    exit 2
  }
  echo "restore: recreating $TARGET"
  psql_cmd "$MAINT_DSN" -v ON_ERROR_STOP=1 \
    -c "drop database if exists \"$TARGET\" with (force)" \
    -c "create database \"$TARGET\""
fi

echo "restore: writing $FILE into $TARGET"
pg_restore_file
echo "restore: done"
