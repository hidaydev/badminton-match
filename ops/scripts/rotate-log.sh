#!/bin/bash
# Rotate the logs of the majadu deployment on the VPS.
#
# Why this exists at all: the deploy log records request paths, and a share link
# is a request path. Logs stay 0600 and never reach a world-readable directory.
#
#   /srv/qouver/apps/majadu/scripts/rotate-log.sh        # by cron, hourly
#   KEEP_DAYS=30 rotate-log.sh                           # longer history
set -euo pipefail

LOG_DIR=${LOG_DIR:-/srv/qouver/apps/majadu/logs}
KEEP_DAYS=${KEEP_DAYS:-14}

[ -d "$LOG_DIR" ] || exit 0

umask 077
stamp=$(date '+%Y%m%d-%H%M%S')

for log in "$LOG_DIR"/*.log; do
  [ -f "$log" ] || continue
  chmod 600 "$log"
  # A rename, not a truncate: the writers append with >>, so the next line
  # lands in a fresh file and nothing is lost between the two steps.
  mv -f "$log" "$log.$stamp"
done

# Pruning by age keeps the volume bound without pretending to know how fast the
# log grows.
find "$LOG_DIR" -type f -name '*.log.*' -mtime +"$KEEP_DAYS" -delete 2>/dev/null || true
