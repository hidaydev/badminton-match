#!/bin/bash
# Rotate the logs of the majadu deployment on the VPS.
#
# Why this exists at all: the deploy log records request paths, and a share link
# is a request path. Logs stay 0600 and never reach a world-readable directory.
#
# A rename alone bounds the age of a file, not its size: a request flood or a
# hot loop can fill the volume between two hourly runs, which takes PostgreSQL
# and the API down with it. The timer therefore runs every ten minutes, every
# closed file is gzipped, and a disk-usage guard pages someone before the
# volume is full instead of after.
#
#   /srv/qouver/apps/majadu/scripts/rotate-log.sh        # by majadu-rotate-log.timer
#   KEEP_DAYS=30 rotate-log.sh                           # longer history
#   MAXSIZE=100M rotate-log.sh                           # rotate a file past this size
#   DISK_MAX_PCT=80 rotate-log.sh                        # page past this usage
set -euo pipefail

LOG_DIR=${LOG_DIR:-/srv/qouver/apps/majadu/logs}
KEEP_DAYS=${KEEP_DAYS:-14}
MAXSIZE=${MAXSIZE:-100M}
DISK_MAX_PCT=${DISK_MAX_PCT:-80}

[ -d "$LOG_DIR" ] || exit 0

umask 077
stamp=$(date '+%Y%m%d-%H%M%S')

# `du -k` is the portable form: `stat -c` is GNU-only and this script has to be
# readable on a developer machine as well as the host.
log_kb() {
  du -k "$1" 2>/dev/null | awk '{print $1 + 0; exit}'
}

maxsize_kb() {
  local value=${MAXSIZE%[kKmMgG]}
  case "$MAXSIZE" in
    *[kK]) printf '%s\n' "$value" ;;
    *[mM]) printf '%s\n' "$((value * 1024))" ;;
    *[gG]) printf '%s\n' "$((value * 1024 * 1024))" ;;
    *) printf '%s\n' "$((value * 1024))" ;;
  esac
}

MAX_KB=$(maxsize_kb)

for log in "$LOG_DIR"/*.log; do
  [ -f "$log" ] || continue
  chmod 600 "$log"
  size=$(log_kb "$log")
  # An empty file is the steady state between two writes: renaming it would
  # create a gzip per timer tick and keep nothing.
  [ "$size" -gt 0 ] || continue
  if [ "$size" -ge "$MAX_KB" ]; then
    printf 'rotate-log: %s reached %s KB, past MAXSIZE=%s\n' \
      "$log" "$size" "$MAXSIZE" >&2
  fi
  # A rename, not a truncate: the writers append with >>, so the next line
  # lands in a fresh file and nothing is lost between the two steps. The file
  # is compressed immediately, so the closed copy is never a second unbounded
  # file on the volume.
  rotated="$log.$stamp"
  mv -f "$log" "$rotated"
  gzip -9 "$rotated"
  chmod 600 "$rotated.gz" 2>/dev/null || true
done

# Pruning by age keeps the volume bound without pretending to know how fast the
# log grows. The pattern covers both the compressed and the older uncompressed
# shape, so a host upgrading this script still deletes its history.
find "$LOG_DIR" -type f \( -name '*.log.*.gz' -o -name '*.log.*' \) \
  -mtime +"$KEEP_DAYS" -delete 2>/dev/null || true

# The disk guard is the part that is not about this application's logs: the
# host runs PostgreSQL and several other services, and a full volume is a
# single failure that takes all of them down. `df -P` gives the usage of the
# filesystem the log directory is on.
used=$(df -P "$LOG_DIR" 2>/dev/null | awk 'NR == 2 {gsub("%", "", $5); print $5 + 0}')
if [ -n "$used" ] && [ "$used" -ge "$DISK_MAX_PCT" ]; then
  printf 'rotate-log: %s is %s%% full (threshold %s%%)\n' \
    "$LOG_DIR" "$used" "$DISK_MAX_PCT" >&2
  if systemctl --user list-unit-files 'majadu-alert@.service' >/dev/null 2>&1; then
    systemctl --user start majadu-alert@disk.service >/dev/null 2>&1 || true
  fi
fi
