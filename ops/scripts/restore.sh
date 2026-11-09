#!/usr/bin/env bash
# Restore a custom-format dump into a database.
#
#   ./ops/scripts/restore.sh --file backups/bm2-20261104-0300.dump --target bm2
#   ./ops/scripts/restore.sh --file dump --target bm_staging --recreate \
#     --dsn postgres://bm2_owner@qouver-postgres:5432/bm_staging
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
# name in --dsn has to equal --target, and a mismatch is refused. The write also
# takes the same deploy lock deploy-vps.sh and cutover.sh use, so a restore
# cannot run while a deploy is swapping the release.
set -euo pipefail

APP_DIR="${MAJADU_APP_DIR:-/srv/qouver/apps/majadu}"
LOCK_FILE="$APP_DIR/.deploy.lock"

FILE=""
TARGET=""
RECREATE=0
FORCE=0
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

# The database pg_restore writes into comes from --dsn, not from --target, so
# the allow-list above is only a guard when both name the same database.
dsn_database() {
  local dsn=$1 rest path
  case "$dsn" in
    postgres://*) rest=${dsn#*://} ;;
    postgresql://*) rest=${dsn#*://} ;;
    *) return 1 ;;
  esac
  case "$rest" in
    */*) path=/${rest#*/} ;;
    *) return 1 ;;
  esac
  path=${path%%\?*}
  path=${path#/}
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

command -v pg_restore >/dev/null 2>&1 || { echo "restore: pg_restore is required" >&2; exit 2; }
command -v psql >/dev/null 2>&1 || { echo "restore: psql is required" >&2; exit 2; }
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

if ! inherits_lock; then
  exec 9>"$LOCK_FILE"
  if ! flock -w 900 9; then
    echo "restore: another deploy or cutover holds $LOCK_FILE; refusing to write into '$TARGET'" >&2
    exit 1
  fi
fi

if ! pg_restore --list "$FILE" >/dev/null 2>&1; then
  echo "restore: $FILE is not a readable custom-format dump" >&2
  exit 1
fi

# Derive the maintenance connection from the target DSN: same host, port and
# role, but the `postgres` database, because the target cannot be dropped from a
# connection to itself. A unix-socket DSN (`postgresql:///db`) carries no host,
# so --recreate refuses it instead of silently dropping a database on whatever
# server the local socket happens to point at.
maintenance_dsn() {
  local dsn=$1 scheme rest authority path query hostport host
  case "$dsn" in
    postgres://*) scheme="postgres" ;;
    postgresql://*) scheme="postgresql" ;;
    *) return 1 ;;
  esac
  rest=${dsn#*://}
  case "$rest" in
    */*) authority=${rest%%/*}; path=/${rest#*/} ;;
    *) authority=$rest; path="" ;;
  esac
  [ -n "$authority" ] || return 1
  query=""
  case "$path" in
    *\?*) query="?${path#*\?}"; path=${path%%\?*} ;;
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
  psql "$MAINT_DSN" -v ON_ERROR_STOP=1 \
    -c "drop database if exists \"$TARGET\" with (force)" \
    -c "create database \"$TARGET\""
fi

echo "restore: writing $FILE into $TARGET"
pg_restore --clean --if-exists --no-owner --no-privileges --dbname "$DSN" "$FILE"
echo "restore: done"
