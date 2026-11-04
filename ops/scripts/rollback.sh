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
# only ever read it. The bm2 data written after the cutover is abandoned; pass
# --drop-bm2 to delete the database instead of leaving it for inspection.
set -euo pipefail

APP_DIR="${MAJADU_APP_DIR:-/srv/qouver/apps/majadu}"
SERVICE="${MAJADU_SERVICE:-majadu-api}"
LOCAL_IMAGE="${MAJADU_IMAGE:-localhost/majadu-api}"
CADDY_CONFIG="${MAJADU_CADDY_CONFIG:-/etc/caddy/Caddyfile}"
CADDY_RELOAD="${MAJADU_CADDY_RELOAD:-sudo systemctl reload caddy}"
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
if [ "${1:-}" = "--drop-bm2" ]; then
  DROP_BM2=1
fi

mkdir -p "$CUTOVER_DIR" "$APP_DIR/logs"

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOG"
}

fail() {
  log "ERROR: $1"
  exit 1
}

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
  systemctl --user daemon-reload
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
caddy validate --config "$CADDY_CONFIG" --adapter caddyfile >/dev/null ||
  fail "Caddy rejected the v1 snippet"
$CADDY_RELOAD
log "caddy serves the v1 site again"

systemctl --user enable "$SERVICE" >/dev/null 2>&1
systemctl --user restart "$SERVICE"
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
OWNER_DSN=""
if [ -f "$APP_DIR/env/majadu-prod.env.v2" ]; then
  OWNER_DSN=$(read_env "$APP_DIR/env/majadu-prod.env.v2" MAJADU_OWNER_DSN)
fi

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
      -c "drop database if exists bm2 with (force)" >>"$LOG" 2>&1
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
