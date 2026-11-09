#!/usr/bin/env bash
# Return production to the previous v2 release after a functional regression.
#
#   ./ops/scripts/release-rollback.sh
#
# This is the v2 -> :prev path. rollback.sh is the different, larger operation
# that returns production to v1 and deletes cutover state; it is not a substitute
# here.
#
# The input is deploy/last-release.json, written only by a successful deploy. The
# script refuses to guess: a missing record, a missing :prev or a :prev without a
# version label is a failed rollback, not a retag. After the restart it waits for
# /readyz, then requires /version to report the previous release, so a stale
# container cannot pass as the rollback.
#
# The schema is not rolled back. The previous release must already serve the
# schema the new one migrated, which is the expand/contract rule in
# docs/ops/release.md.
#
# Env: MAJADU_APP_DIR, MAJADU_SERVICE, MAJADU_IMAGE, MAJADU_HEALTH_URL,
#      MAJADU_STATE_DIR, MAJADU_SYSTEMCTL_CMD.
set -Eeuo pipefail

# The log holds request paths and share codes are bearer credentials, so every
# file these scripts create is private from the first byte instead of waiting for
# the hourly rotation to chmod it.
umask 077


APP_DIR="${MAJADU_APP_DIR:-/srv/qouver/apps/majadu}"
SERVICE="${MAJADU_SERVICE:-majadu-api}"
LOCAL_IMAGE="${MAJADU_IMAGE:-localhost/majadu-api}"
HEALTH_URL="${MAJADU_HEALTH_URL:-http://127.0.0.1:8080}"
STATE_DIR="${MAJADU_STATE_DIR:-$APP_DIR/deploy}"
SYSTEMCTL="${MAJADU_SYSTEMCTL_CMD:-systemctl --user}"
LOG="$APP_DIR/logs/release-rollback.log"

install -d -m 700 "$APP_DIR/logs" "$STATE_DIR"
: >>"$LOG"
chmod 600 "$LOG" 2>/dev/null || true

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOG"
}

alert() {
  if $SYSTEMCTL list-unit-files 'majadu-alert@.service' >/dev/null 2>&1; then
    $SYSTEMCTL start majadu-alert@release-rollback.service >/dev/null 2>&1 || true
  fi
}

fail() {
  log "ERROR: $1"
  alert
  exit 1
}

trap 'fail "command failed at line $LINENO"' ERR

usage() {
  sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'
}

case "${1:-}" in
  "") ;;
  -h|--help) usage; exit 0 ;;
  *) printf 'release-rollback: unknown argument %s\n' "$1" >&2; exit 2 ;;
esac

command -v podman >/dev/null 2>&1 || fail "podman is required"
command -v curl >/dev/null 2>&1 || fail "curl is required"

STATE_FILE="$STATE_DIR/last-release.json"
[ -f "$STATE_FILE" ] || fail "$STATE_FILE is missing; refusing to guess what is running"

json_field() {
  sed -n "s/.*\"$2\":\"\([^\"]*\)\".*/\1/p" "$1" 2>/dev/null | head -1
}

current_version=$(json_field "$STATE_FILE" version)
current_schema=$(json_field "$STATE_FILE" schema)
[ -n "$current_version" ] || fail "$STATE_FILE has no version field"

podman image exists "$LOCAL_IMAGE:prev" ||
  fail "$LOCAL_IMAGE:prev is missing; there is no previous release to restore"

prev_version=""
prev_commit=""
prev_digest=""
prev_schema=""
PREV_STATE="$STATE_DIR/last-release.json.prev"
if [ -f "$PREV_STATE" ]; then
  prev_version=$(json_field "$PREV_STATE" version)
  prev_commit=$(json_field "$PREV_STATE" commit)
  prev_digest=$(json_field "$PREV_STATE" digest)
  prev_schema=$(json_field "$PREV_STATE" schema)
fi
if [ -z "$prev_version" ]; then
  prev_version=$(podman image inspect --format \
    '{{ index .Labels "org.opencontainers.image.version" }}' "$LOCAL_IMAGE:prev" 2>/dev/null || true)
fi
case "$prev_version" in
  ''|'<no value>') fail "$LOCAL_IMAGE:prev has no recorded version; refusing to record an unnamed release" ;;
esac
[ -n "$prev_commit" ] || prev_commit="unknown"
[ -n "$prev_digest" ] || prev_digest="unknown"
[ -n "$prev_schema" ] || prev_schema="${current_schema:-unknown}"

log "rolling back from v$current_version to v$prev_version ($prev_commit)"

# Keep the bad release's record for the incident note before replacing it.
cp -f "$STATE_FILE" "$STATE_DIR/last-release.json.rolled-back"

podman tag "$LOCAL_IMAGE:prev" "$LOCAL_IMAGE:local"
$SYSTEMCTL restart "$SERVICE"

deadline=$((SECONDS + 60))
healthy=0
while [ "$SECONDS" -lt "$deadline" ]; do
  if curl -fsS --max-time 3 "$HEALTH_URL/readyz" >/dev/null 2>&1; then
    healthy=1
    break
  fi
  sleep 2
done
[ "$healthy" -eq 1 ] || fail "v$prev_version did not answer /readyz within 60s"

served=$(curl -fsS --max-time 5 "$HEALTH_URL/version" 2>/dev/null || true)
case "$served" in
  *"\"version\":\"$prev_version\""*) ;;
  *) fail "/version does not report v$prev_version after the rollback (got '${served:-<none>}')" ;;
esac

printf '%s\n' "$prev_version" >"$STATE_DIR/deployed-version"
printf '{"version":"%s","commit":"%s","digest":"%s","schema":"%s","at":"%s"}\n' \
  "$prev_version" "$prev_commit" "$prev_digest" "${current_schema:-unknown}" \
  "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
  >"$STATE_FILE"

log "rolled back to v$prev_version; deployed-version and last-release.json updated"
