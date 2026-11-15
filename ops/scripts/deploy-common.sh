#!/usr/bin/env bash
# Helpers shared by the two deploy scripts (SQ-16).
#
# `deploy-vps.sh` pulls a signed image by digest; `deploy-vps-rc.sh` builds the
# RC branch on the host. The paths differ on purpose, but the logging, the
# state-file reader, the service indirection, the alert trigger and the
# readiness probe have to behave the same or the two records cannot be read the
# same way. This file is sourced by both, so a fix lands in both.
#
# This is a library, not a program. It reads these globals from the sourcing
# script and must not define them:
#   LOG          the log file `log` appends to
#   HEALTH_URL   the base URL `wait_ready` polls
#   ALERT_UNIT   the `majadu-alert@<unit>.service` instance `alert` starts
# It also relies on `set -Eeuo pipefail` being in force, which both scripts set
# before sourcing.

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOG"
}

json_field() {
  # A missing state file is the first deploy, not a failure. GNU sed exits 2 on
  # it, and `set -o pipefail` turned that into a failed `fail()` before its
  # message was written.
  [ -f "$1" ] || return 0
  sed -n "s/.*\"$2\":\"\([^\"]*\)\".*/\1/p" "$1" 2>/dev/null | head -1
}

alert() {
  [ -n "${ALERT_UNIT:-}" ] || return 0
  if systemctl --user list-unit-files 'majadu-alert@.service' >/dev/null 2>&1; then
    systemctl --user start "majadu-alert@${ALERT_UNIT}.service" >/dev/null 2>&1 || true
  fi
}

# -L: a credential reached through a symlink is judged by the file it points at.
# The cutover points majadu-prod.env at a versioned file, and without this the
# link's own 777 mode fails the private-env gate on a file that is really 600.
file_mode() {
  stat -Lc '%a' "$1" 2>/dev/null || stat -Lf '%Lp' "$1" 2>/dev/null || echo "?"
}

service() {
  if [ -n "${MAJADU_SERVICE_CMD:-}" ]; then
    "$MAJADU_SERVICE_CMD" "$@"
  else
    systemctl --user "$@"
  fi
}

wait_ready() {
  local deadline=$((SECONDS + 60))
  while [ "$SECONDS" -lt "$deadline" ]; do
    if curl -fsS --max-time 3 "$HEALTH_URL/readyz" >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  return 1
}
