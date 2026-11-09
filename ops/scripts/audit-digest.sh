#!/usr/bin/env bash
# Write a daily tamper-evidence digest of account.audit next to the dumps.
#
#   ops/scripts/audit-digest.sh
#
# The application cannot rewrite or delete audit rows, which is a real control.
# The owner role could, and the same role used to run retention. This script is
# what makes that visible after the fact: one digest per day, written into the
# backup directory that is copied off the host, so a row edited between two days
# changes a file the database cannot reach.
#
# It creates no table and needs no migration. Env: MAJADU_APP_DIR,
# MAJADU_BACKUP_DIR, MAJADU_AUDIT_DSN (falls back to the tool env), and
# MAJADU_PG_CONTAINER for the container fallback.
set -Eeuo pipefail

umask 077

APP_DIR="${MAJADU_APP_DIR:-/srv/qouver/apps/majadu}"
TOOLS_ENV="$APP_DIR/env/majadu-tools.env"
OUT_DIR="${MAJADU_BACKUP_DIR:-$APP_DIR/backups}"
PG_CONTAINER="${MAJADU_PG_CONTAINER:-qouver-postgres}"
DSN="${MAJADU_AUDIT_DSN:-}"

if [ -z "$DSN" ] && [ -f "$TOOLS_ENV" ]; then
  DSN=$(sed -n 's/^MAJADU_AUDIT_DSN=//p' "$TOOLS_ENV" | tail -1)
fi
if [ -z "$DSN" ]; then
  echo "audit-digest: MAJADU_AUDIT_DSN is not set and not in $TOOLS_ENV" >&2
  exit 2
fi

USE_CONTAINER=0
if ! command -v psql >/dev/null 2>&1; then
  USE_CONTAINER=1
  command -v podman >/dev/null 2>&1 ||
    { echo "audit-digest: host has no psql and podman is not installed" >&2; exit 2; }
  podman container exists "$PG_CONTAINER" 2>/dev/null ||
    { echo "audit-digest: host has no psql and container '$PG_CONTAINER' does not exist" >&2; exit 2; }
fi

query() {
  if [ "$USE_CONTAINER" -eq 1 ]; then
    podman exec "$PG_CONTAINER" psql "$DSN" -tAc "$1"
  else
    psql "$DSN" -tAc "$1"
  fi
}

# One row per audit row, hashed, then hashed again as a multiset: the value
# changes when a row is added, removed or edited, and it does not depend on the
# order PostgreSQL returns the rows in.
answer=$(query "select count(*) || ':' || coalesce(md5(string_agg(md5(a::text), '' order by md5(a::text))), '') from account.audit a")
rows=${answer%%:*}
digest=${answer#*:}
case "$rows" in
  ''|*[!0-9]*) echo "audit-digest: unexpected answer '$answer'" >&2; exit 1 ;;
esac
[ -n "$digest" ] || { echo "audit-digest: empty digest" >&2; exit 1; }

install -d -m 700 "$OUT_DIR"
stamp=$(date -u '+%Y%m%d')
dest="$OUT_DIR/audit-digest-$stamp.json"
tmp="$dest.tmp.$$"
printf '{"rows":%s,"digest":"%s","at":"%s"}\n' \
  "$rows" "$digest" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" >"$tmp"
sync
mv -f "$tmp" "$dest"
printf 'audit-digest: %s audit rows, digest %s written to %s\n' \
  "$rows" "$digest" "$dest"
