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

command -v pg_dump >/dev/null 2>&1 || { echo "backup: pg_dump is required" >&2; exit 2; }
command -v pg_restore >/dev/null 2>&1 || { echo "backup: pg_restore is required" >&2; exit 2; }

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
  ( umask 077; pg_dump --format=custom --no-owner "$dsn" >"$tmp" )
  if ! pg_restore --list "$tmp" >/dev/null 2>&1; then
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
dump_one bm2 "${MAJADU_BACKUP_DSN_BM2:-${MAJADU_PG_DSN:-}}" 0

log "backup done"
