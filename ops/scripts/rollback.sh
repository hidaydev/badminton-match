#!/usr/bin/env bash
# Return production to v1 after a failed or regretted cutover.
#
#   ./ops/scripts/rollback.sh
#   ./ops/scripts/rollback.sh --drop-bm2
#
# Only this script re-enables the v1 unit and removes `cutover_state`: that is
# what makes a second cutover possible. Everything it needs was saved by
# cutover.sh while v1 was still running - the image (:v1-final), the unit file,
# the env target and the Caddy snippet.
#
# `bm` is never written to: rollback does not restore it, because the cutover
# only ever read it. The bm2 data written after the cutover is abandoned, so the
# script counts those rows first and refuses to run until that loss is confirmed
# with --abandon-data. Pass --drop-bm2 to delete the database instead of leaving
# it for inspection.
#
# Env (in addition to MAJADU_APP_DIR): MAJADU_SYSTEMCTL_CMD, MAJADU_CADDY_VALIDATE
# and MAJADU_BM2_DB exist for the rehearsal harness (T-063), the same overrides
# cutover.sh takes.
set -euo pipefail

APP_DIR="${MAJADU_APP_DIR:-/srv/qouver/apps/majadu}"
SERVICE="${MAJADU_SERVICE:-majadu-api}"
LOCAL_IMAGE="${MAJADU_IMAGE:-localhost/majadu-api}"
CADDY_CONFIG="${MAJADU_CADDY_CONFIG:-/etc/caddy/Caddyfile}"
CADDY_RELOAD="${MAJADU_CADDY_RELOAD:-sudo systemctl reload caddy}"
CADDY_VALIDATE="${MAJADU_CADDY_VALIDATE:-caddy validate}"
SYSTEMCTL="${MAJADU_SYSTEMCTL_CMD:-systemctl --user}"
BM2_DB="${MAJADU_BM2_DB:-bm2}"
HEALTH_URL="${MAJADU_HEALTH_URL:-http://127.0.0.1:8080}"
CADDY_DIR="$APP_DIR/caddy"
CADDY_ACTIVE="$CADDY_DIR/active.caddy"
ENV_LINK="$APP_DIR/env/majadu-prod.env"
ENV_V1="$APP_DIR/env/majadu-prod.env.v1"
CUTOVER_DIR="$APP_DIR/cutover"
LOCK_FILE="$APP_DIR/.deploy.lock"
STEP_FILE="$CUTOVER_DIR/cutover.step"
LOG="$APP_DIR/logs/rollback.log"

DROP_BM2=0
ABANDON_DATA=0

mkdir -p "$CUTOVER_DIR" "$APP_DIR/logs"

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOG"
}

fail() {
  log "ERROR: $1"
  exit 1
}

for arg in "$@"; do
  case "$arg" in
    --drop-bm2) DROP_BM2=1 ;;
    --abandon-data) ABANDON_DATA=1 ;;
    *) fail "unknown argument: $arg" ;;
  esac
done

command -v podman >/dev/null 2>&1 || fail "podman is required"

exec 9>"$LOCK_FILE"
if ! flock -w 900 9; then
  fail "another deploy or cutover holds the lock"
fi

podman image exists "$LOCAL_IMAGE:v1-final" ||
  fail ":v1-final is gone; v2 cannot be rolled back safely"

read_env() {
  local file="$1" key="$2"
  sed -n "s/^$key=//p" "$file" 2>/dev/null | tail -1
}

OWNER_DSN=""
if [ -f "$APP_DIR/env/majadu-prod.env.v2" ]; then
  OWNER_DSN=$(read_env "$APP_DIR/env/majadu-prod.env.v2" MAJADU_OWNER_DSN)
fi

# ---------------------------------------------------------------------------
# Guard: how much v2 work does this rollback throw away? The answer decides
# whether the operator meant it, so it is asked before anything is changed.
# ---------------------------------------------------------------------------
if [ -n "$OWNER_DSN" ] && command -v psql >/dev/null 2>&1; then
  abandoned=$(psql "$OWNER_DSN" -Atc "
    select
      (select count(*) from session.sessions where updated_at >= c.completed_at)
    + (select count(*) from session.games where updated_at >= c.completed_at)
    + (select count(*) from player.players where updated_at >= c.completed_at)
    + (select count(*) from tournament.tournaments where updated_at >= c.completed_at)
    + (select count(*) from rating.events where created_at >= c.completed_at)
    from platform.cutover_state c
    where c.id and c.completed_at is not null" 2>/dev/null || true)
  case "$abandoned" in
    ''|*[!0-9]*) abandoned="" ;;
  esac
  if [ -n "$abandoned" ] && [ "$abandoned" -gt 0 ]; then
    if [ "$ABANDON_DATA" -ne 1 ]; then
      fail "$abandoned row(s) were written to v2 since the cutover; rollback discards them. Re-run with --abandon-data to confirm that loss."
    fi
    log "WARNING: abandoning $abandoned row(s) written since the cutover"
  fi
fi

# ---------------------------------------------------------------------------
# Image: v1-final becomes :local. `:prev` is left alone; the next deploy
# rotates it as usual.
# ---------------------------------------------------------------------------
log "restoring :v1-final as :local"
podman tag "$LOCAL_IMAGE:v1-final" "$LOCAL_IMAGE:local"

# ---------------------------------------------------------------------------
# Unit and env: the copies saved before v1 was stopped, not a reconstruction.
# ---------------------------------------------------------------------------
if [ -f "$CUTOVER_DIR/$SERVICE.container.v1" ]; then
  install -m 644 "$CUTOVER_DIR/$SERVICE.container.v1" \
    "$HOME/.config/containers/systemd/$SERVICE.container"
  $SYSTEMCTL daemon-reload
  log "restored the v1 unit file"
fi

ENV_TARGET="$ENV_V1"
[ -f "$CUTOVER_DIR/env-target.v1" ] && ENV_TARGET=$(cat "$CUTOVER_DIR/env-target.v1")
if [ -f "$ENV_TARGET" ]; then
  ln -sfn "$ENV_TARGET" "$ENV_LINK"
  log "env now points at $ENV_TARGET"
else
  log "WARNING: $ENV_TARGET is missing; leaving the env link untouched"
fi

# ---------------------------------------------------------------------------
# Caddy first, so the site is answered by the process that is about to start.
# ---------------------------------------------------------------------------
ln -sfn "$CADDY_DIR/site-v1.caddy" "$CADDY_ACTIVE"
$CADDY_VALIDATE --config "$CADDY_CONFIG" --adapter caddyfile >/dev/null ||
  fail "Caddy rejected the v1 snippet"
$CADDY_RELOAD
log "caddy serves the v1 site again"

$SYSTEMCTL enable "$SERVICE" >/dev/null 2>&1
$SYSTEMCTL restart "$SERVICE"
log "v1 unit enabled and started"

# ---------------------------------------------------------------------------
# v1 has no /readyz; liveness is the strongest signal it offers.
# ---------------------------------------------------------------------------
deadline=$((SECONDS + 60))
healthy=0
while [ "$SECONDS" -lt "$deadline" ]; do
  if curl -fsS --max-time 3 "$HEALTH_URL/healthz" >/dev/null 2>&1; then
    healthy=1
    break
  fi
  sleep 2
done
if [ "$healthy" -eq 1 ]; then
  log "v1 answers /healthz"
else
  log "ERROR: v1 did not answer /healthz within 60s"
fi

# ---------------------------------------------------------------------------
# Archive the cutover row, then delete it so a new cutover is not blocked.
# bm2 holds the audit table, which is exactly the database being abandoned, so
# the row also goes to a file next to the other cutover artefacts.
# ---------------------------------------------------------------------------
if [ -n "$OWNER_DSN" ] && command -v psql >/dev/null 2>&1; then
  if psql "$OWNER_DSN" -Atc \
    "select row_to_json(c) from platform.cutover_state c where id" \
    >"$CUTOVER_DIR/state-archive.json" 2>/dev/null; then
    psql "$OWNER_DSN" -c "delete from platform.cutover_state where id" \
      >>"$LOG" 2>&1 || log "WARNING: could not delete the cutover row"
    log "cutover state archived to $CUTOVER_DIR/state-archive.json and cleared"
  fi
  if [ "$DROP_BM2" -eq 1 ]; then
    psql "$OWNER_DSN" -v ON_ERROR_STOP=1 \
      -c "drop database if exists $BM2_DB with (force)" >>"$LOG" 2>&1
    log "bm2 dropped as requested"
  else
    log "bm2 left in place; its post-cutover data is abandoned (--drop-bm2 deletes it)"
  fi
else
  log "WARNING: no bm2 DSN found; cutover_state may still block the next cutover"
fi

printf '{"step":"rollback","state":"done","at":"%s"}\n' \
  "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" >"$STEP_FILE"

if [ "$healthy" -eq 1 ]; then
  log "rollback complete"
else
  exit 1
fi
