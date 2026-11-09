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
set -Eeuo pipefail

APP_DIR="${MAJADU_APP_DIR:-/srv/qouver/apps/majadu}"
SERVICE="${MAJADU_SERVICE:-majadu-api}"
LOCAL_IMAGE="${MAJADU_IMAGE:-localhost/majadu-api}"
CADDY_CONFIG="${MAJADU_CADDY_CONFIG:-/etc/caddy/Caddyfile}"
CADDY_RELOAD="${MAJADU_CADDY_RELOAD:-sudo systemctl reload caddy}"
CADDY_VALIDATE="${MAJADU_CADDY_VALIDATE:-caddy validate}"
SYSTEMCTL="${MAJADU_SYSTEMCTL_CMD:-systemctl --user}"
BM2_DB="${MAJADU_BM2_DB:-bm2}"
PG_CONTAINER="${MAJADU_PG_CONTAINER:-qouver-postgres}"
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

# Same sink as deploy-vps.sh and cutover.sh: a rollback that fails leaves the
# site in maintenance, which must page someone. No-op when the alert template
# is not installed.
alert() {
  local unit="${MAJADU_ALERT_UNIT:-$(basename "$0" .sh)}"
  if $SYSTEMCTL list-unit-files 'majadu-alert@.service' >/dev/null 2>&1; then
    $SYSTEMCTL start "majadu-alert@$unit.service" >/dev/null 2>&1 || true
  fi
}

fail() {
  log "ERROR: $1"
  alert
  exit 1
}

# A mistyped flag is not an incident: log it and exit without paging.
usage_fail() {
  log "ERROR: $1"
  exit 1
}

# Every step below either succeeds or pages: a rollback that stops halfway
# leaves production in the state the cutover created.
trap 'fail "command failed at line $LINENO"' ERR

for arg in "$@"; do
  case "$arg" in
    --drop-bm2) DROP_BM2=1 ;;
    --abandon-data) ABANDON_DATA=1 ;;
    *) usage_fail "unknown argument: $arg" ;;
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

# The owner DSN belongs to the deploy and cutover tools, so it lives in the tool
# env, not in the file the API unit loads. The v2 env fallback keeps the T-063
# rehearsal sandbox, which installs a single v2 env, running.
TOOLS_ENV="$APP_DIR/env/majadu-tools.env"
V2_ENV="$APP_DIR/env/majadu-prod.env.v2"
OWNER_DSN=""
if [ -f "$TOOLS_ENV" ]; then
  OWNER_DSN=$(read_env "$TOOLS_ENV" MAJADU_OWNER_DSN)
  [ -z "$OWNER_DSN" ] || log "rollback reads the owner DSN from $TOOLS_ENV"
elif [ -f "$V2_ENV" ]; then
  OWNER_DSN=$(read_env "$V2_ENV" MAJADU_OWNER_DSN)
  log "WARNING: $TOOLS_ENV is missing; reading the owner DSN from $V2_ENV (rehearsal fallback)"
fi
if [ -z "$OWNER_DSN" ]; then
  log "WARNING: no owner DSN available; the abandoned-row guard will be skipped, so v2 writes since the cutover are not counted"
fi

# ---------------------------------------------------------------------------
# Guard: how much v2 work does this rollback throw away? The answer decides
# whether the operator meant it, so it is asked before anything is changed.
# ---------------------------------------------------------------------------
if [ -z "$OWNER_DSN" ]; then
  if [ "$ABANDON_DATA" -ne 1 ]; then
    fail "cannot count bm2 rows written since the cutover: no owner DSN. Pass --abandon-data to confirm that the loss is accepted."
  fi
  log "WARNING: no owner DSN; --abandon-data given and the abandoned-row count is unknown"
fi

# The guard is unconditional. On the documented host psql is not installed, so
# the count runs inside the PostgreSQL container; when neither client works the
# script refuses rather than silently discarding rows the operator never saw.
psql_owner() {
  if command -v psql >/dev/null 2>&1; then
    psql "$@"
  else
    command -v podman >/dev/null 2>&1 || return 1
    podman exec -i "$PG_CONTAINER" psql "$@"
  fi
}

if [ -n "$OWNER_DSN" ]; then
  abandoned=$(psql_owner "$OWNER_DSN" -Atc "
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
  if [ -z "$abandoned" ]; then
    if [ "$ABANDON_DATA" -ne 1 ]; then
      fail "cannot count bm2 rows written since the cutover (no psql and no usable '$PG_CONTAINER' container). Pass --abandon-data to confirm that the loss is accepted."
    fi
    log "WARNING: cannot count abandoned rows; --abandon-data given, the count is unknown"
  elif [ "$abandoned" -gt 0 ]; then
    if [ "$ABANDON_DATA" -ne 1 ]; then
      fail "$abandoned row(s) were written to bm2 since the cutover; rollback discards them. Re-run with --abandon-data to confirm that loss."
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
# Service first: v1 has to answer before anything optional is touched.
# cutover.sh stopped and disabled the unit, so until this restart nothing is
# serving. Every command here is idempotent, so a retry after a partial run is
# safe.
# ---------------------------------------------------------------------------
if ! $SYSTEMCTL enable "$SERVICE" >/dev/null 2>&1; then
  log "WARNING: could not enable $SERVICE; it runs but will not start after a reboot"
fi
$SYSTEMCTL restart "$SERVICE"
log "v1 unit enabled and started"

# ---------------------------------------------------------------------------
# v1 has no /readyz; liveness is the strongest signal it offers. A service that
# does not answer is a failed rollback, and it pages.
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
  fail "v1 did not answer /healthz within 60s after the restart"
fi

# ---------------------------------------------------------------------------
# Caddy last: the site snippet is optional relative to a running service, and
# the live server runs Caddy with `admin off`, which makes `systemctl reload`
# fail. Point the active snippet at v1 and try to reload, but a failure here is
# a paged partial rollback, not a dead site.
# ---------------------------------------------------------------------------
ln -sfn "$CADDY_DIR/site-v1.caddy" "$CADDY_ACTIVE"
if ! $CADDY_VALIDATE --config "$CADDY_CONFIG" --adapter caddyfile >/dev/null; then
  fail "Caddy rejected the v1 snippet; v1 is running and healthy, the site is not switched"
fi
if ! $CADDY_RELOAD; then
  fail "Caddy reload failed (admin off?); v1 is running and healthy, the site is not switched"
fi
log "caddy serves the v1 site again"

# ---------------------------------------------------------------------------
# Archive the cutover row, then delete it so a new cutover is not blocked.
# bm2 holds the audit table, which is exactly the database being abandoned, so
# the row also goes to a file next to the other cutover artefacts.
# ---------------------------------------------------------------------------
if [ -n "$OWNER_DSN" ]; then
  if psql_owner "$OWNER_DSN" -Atc \
    "select row_to_json(c) from platform.cutover_state c where id" \
    >"$CUTOVER_DIR/state-archive.json" 2>/dev/null; then
    psql_owner "$OWNER_DSN" -c "delete from platform.cutover_state where id" \
      >>"$LOG" 2>&1 || log "WARNING: could not delete the cutover row"
    log "cutover state archived to $CUTOVER_DIR/state-archive.json and cleared"
  fi
  if [ "$DROP_BM2" -eq 1 ]; then
    psql_owner "$OWNER_DSN" -v ON_ERROR_STOP=1 \
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

log "rollback complete"
