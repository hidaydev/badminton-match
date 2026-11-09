#!/usr/bin/env bash
# Nightly dump of the databases, plus the extra dump every destructive step
# makes first.
#
#   ./ops/scripts/backup.sh                # rotating daily dumps
#   ./ops/scripts/backup.sh --tag cutover  # one dump outside the rotation
#
# Env:
#   MAJADU_BACKUP_DIR        default /srv/qouver/apps/majadu/backups
#   MAJADU_BACKUP_DSN_BM     v1 archive; skipped when unset
#   MAJADU_BACKUP_DSN_BM2    v2 production; skipped when unset
#   MAJADU_BACKUP_KEEP_DAYS  rotation for bm2 (default 7)
#   MAJADU_BACKUP_KEEP_BM_DAYS rotation for bm (default 30)
#
# A dump is only moved into place after `pg_restore --list` has read it, so a
# truncated file never looks like a backup. Files are mode 600.
set -euo pipefail

APP_DIR="${MAJADU_APP_DIR:-/srv/qouver/apps/majadu}"
BACKUP_DIR="${MAJADU_BACKUP_DIR:-$APP_DIR/backups}"
KEEP_DAYS="${MAJADU_BACKUP_KEEP_DAYS:-7}"
KEEP_BM_DAYS="${MAJADU_BACKUP_KEEP_BM_DAYS:-30}"
TOOLS_ENV="${MAJADU_TOOLS_ENV:-$APP_DIR/env/majadu-tools.env}"
PG_CONTAINER="${MAJADU_PG_CONTAINER:-qouver-postgres}"
USE_CONTAINER=0

TAG=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --tag)
      shift
      [ "$#" -gt 0 ] || { echo "backup: --tag needs a value" >&2; exit 2; }
      TAG="$1"
      ;;
    *)
      echo "backup: unknown argument $1" >&2
      exit 2
      ;;
  esac
  shift
done

log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }

for tool in pg_dump pg_restore; do
  command -v "$tool" >/dev/null 2>&1 || USE_CONTAINER=1
done
if [ "$USE_CONTAINER" -eq 1 ]; then
  command -v podman >/dev/null 2>&1 ||
    { echo "backup: host has no pg_dump/pg_restore and podman is not installed" >&2; exit 2; }
  podman container exists "$PG_CONTAINER" 2>/dev/null ||
    { echo "backup: host has no pg_dump/pg_restore and container '$PG_CONTAINER' does not exist" >&2; exit 2; }
fi

pg_dump_cmd() {
  if [ "$USE_CONTAINER" -eq 1 ]; then
    podman exec "$PG_CONTAINER" pg_dump "$@"
  else
    pg_dump "$@"
  fi
}

pg_restore_list_cmd() {
  if [ "$USE_CONTAINER" -eq 1 ]; then
    podman exec -i "$PG_CONTAINER" pg_restore --list <"$1"
  else
    pg_restore --list "$1"
  fi
}

mkdir -p "$BACKUP_DIR"
chmod 700 "$BACKUP_DIR"

stamp=$(date '+%Y%m%d-%H%M%S')

dump_one() {
  local name="$1" dsn="$2" legacy="$3" file tmp
  if [ -z "$dsn" ]; then
    log "skipping $name: no DSN configured"
    return 0
  fi
  file="$BACKUP_DIR/$name-$stamp.dump"
  if [ -n "$TAG" ]; then
    file="$BACKUP_DIR/$name-$TAG-$stamp.dump"
  fi
  tmp="$file.partial"

  log "dumping $name"
  ( umask 077; pg_dump_cmd --format=custom --no-owner "$dsn" >"$tmp" )
  if ! pg_restore_list_cmd "$tmp" >/dev/null 2>&1; then
    rm -f "$tmp"
    echo "backup: $name dump is not readable; refusing to keep it" >&2
    exit 1
  fi
  mv "$tmp" "$file"
  chmod 600 "$file"
  log "wrote $file ($(du -h "$file" | cut -f1))"

  if [ -z "$TAG" ]; then
    local keep="$KEEP_DAYS"
    [ "$legacy" = "1" ] && keep="$KEEP_BM_DAYS"
    # Only the timestamped names (`<db>-YYYYmmdd-HHMMSS.dump`) rotate. A dump
    # made with `--tag` carries an extra segment and is evidence an operator
    # asked to keep, so it is never pruned -- matching on the timestamp instead
    # of excluding "*-$TAG-*" (empty here, i.e. `*--*`) is what makes that true.
    find "$BACKUP_DIR" -maxdepth 1 -type f -mtime "+$keep" \
      -name "$name-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9].dump" \
      -print -delete | while read -r old; do log "removed $old (older than $keep days)"; done
  fi
}

dump_one bm "${MAJADU_BACKUP_DSN_BM:-}" 1

# The bm2 dump must be taken as an owner, not as bm2_app. A dump taken as the
# application role cannot see dbtools.schema_migrations (no USAGE), and a restore
# of it produces a database with no migration ledger. The preferred source is
# the tool env; MAJADU_PG_DSN remains a last-resort fallback so an existing host
# keeps making a (degraded) backup instead of none.
BACKUP_DSN_BM2="${MAJADU_BACKUP_DSN_BM2:-}"
if [ -z "$BACKUP_DSN_BM2" ] && [ -f "$TOOLS_ENV" ]; then
  BACKUP_DSN_BM2=$(sed -n 's/^MAJADU_BACKUP_DSN_BM2=//p' "$TOOLS_ENV" | tail -1)
  if [ -z "$BACKUP_DSN_BM2" ]; then
    BACKUP_DSN_BM2=$(sed -n 's/^MAJADU_OWNER_DSN=//p' "$TOOLS_ENV" | tail -1)
  fi
fi
if [ -z "$BACKUP_DSN_BM2" ]; then
  log "WARNING: no owner DSN for bm2; falling back to MAJADU_PG_DSN, whose dump has no migration ledger"
  BACKUP_DSN_BM2="${MAJADU_PG_DSN:-}"
fi
dump_one bm2 "$BACKUP_DSN_BM2" 0

log "backup done"
