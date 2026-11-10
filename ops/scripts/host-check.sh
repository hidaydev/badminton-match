#!/usr/bin/env bash
# Page when the host is about to take itself down.
#
#   ops/scripts/host-check.sh        # by majadu-host-check.timer, every 5 minutes
#
# The API writes one JSON line per request to stdout, so journald is the only
# copy of the access log. A full disk or an OOM kill is the failure that takes
# PostgreSQL, the API and the deploy down together, and the only existing
# symptom is a container that restarted. This checks the two resources and
# starts the alert template directly.
#
# Env: MAJADU_APP_DIR, MAJADU_SERVICE, MAJADU_IMAGE, MIN_FREE_MB (2048),
# MAJADU_SYSTEMCTL_CMD.
set -Eeuo pipefail

umask 077

APP_DIR="${MAJADU_APP_DIR:-/srv/qouver/apps/majadu}"
SERVICE="${MAJADU_SERVICE:-majadu-api}"
LOCAL_IMAGE="${MAJADU_IMAGE:-localhost/majadu-api}"
MIN_FREE_MB="${MIN_FREE_MB:-2048}"
SYSTEMCTL="${MAJADU_SYSTEMCTL_CMD:-systemctl --user}"
LOG="$APP_DIR/logs/host-check.log"

install -d -m 700 "$APP_DIR/logs"
: >>"$LOG"
chmod 600 "$LOG" 2>/dev/null || true

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOG"
}

alert() {
  if $SYSTEMCTL list-unit-files 'majadu-alert@.service' >/dev/null 2>&1; then
    $SYSTEMCTL start "majadu-alert@$1.service" >/dev/null 2>&1 || true
  fi
}

problems=0

# `-P` is the portable output: the mount point is the last field, so a path
# with a space cannot shift the free-block column.
free_mb=$(df -Pm "$APP_DIR" 2>/dev/null | awk 'NR == 2 {print $4 + 0}')
if [ -z "$free_mb" ]; then
  log "WARNING: cannot read free space for $APP_DIR"
elif [ "$free_mb" -lt "$MIN_FREE_MB" ]; then
  log "ERROR: $APP_DIR has ${free_mb} MB free, below ${MIN_FREE_MB} MB"
  problems=$((problems + 1))
  alert disk
fi

# A container that was OOM-killed restarts on its own, so the next health check
# passes and the kill disappears. The flag stays set until the container is
# recreated, which is exactly the window this check needs.
oom=""
if command -v podman >/dev/null 2>&1; then
  oom=$(podman inspect --format '{{.State.OOMKilled}}' "$SERVICE" 2>/dev/null || true)
fi
case "$oom" in
  true)
    log "ERROR: $SERVICE was OOM-killed; MemoryMax is the ceiling it hit"
    problems=$((problems + 1))
    alert memory
    ;;
esac

# The image tag is not the running image after a manual retag: a restart is
# enough to leave what `deployed-version` says behind. The deploy checks this
# too; this catches the case between two deploys.
if command -v podman >/dev/null 2>&1 && podman image exists "$LOCAL_IMAGE:local" 2>/dev/null; then
  running=$(podman inspect --format '{{.Image}}' "$SERVICE" 2>/dev/null || true)
  local_id=$(podman image inspect --format '{{.Id}}' "$LOCAL_IMAGE:local" 2>/dev/null || true)
  if [ -n "$running" ] && [ -n "$local_id" ] && [ "$running" != "$local_id" ]; then
    log "WARNING: $SERVICE is not running $LOCAL_IMAGE:local"
  fi
fi

# ISO-22: the journal is the only copy of the access log, so an uncapped journal
# is a slow disk fill that takes PostgreSQL and the API down with it. The
# drop-in is a one-time root install (ops/journald/majadu.conf) and nothing in
# the deploy path can write /etc, so this is the check that it happened. Both
# files are readable by the deploy user, and the last SystemMaxUse seen wins,
# which is the order systemd applies (drop-ins over the main file).
JOURNALD_CONF="${MAJADU_JOURNALD_CONF:-/etc/systemd/journald.conf}"
JOURNALD_DIR="${MAJADU_JOURNALD_DIR:-/etc/systemd/journald.conf.d}"
journal_cap=""
for file in "$JOURNALD_CONF" "$JOURNALD_DIR"/*.conf; do
  [ -f "$file" ] || continue
  found=$(sed -n 's/^[[:space:]]*SystemMaxUse=[[:space:]]*//p' "$file" | tail -1)
  [ -z "$found" ] || journal_cap="$found"
done
if [ -z "$journal_cap" ]; then
  log "ERROR: no SystemMaxUse in $JOURNALD_CONF or $JOURNALD_DIR; the journal is unbounded"
  problems=$((problems + 1))
  alert disk
fi

[ "$problems" -eq 0 ] || exit 1
log "ok: ${free_mb} MB free, no OOM kill"
