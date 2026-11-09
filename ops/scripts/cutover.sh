#!/usr/bin/env bash
# One manual cutover from the v1 database (`bm`) to v2 (`bm2`).
#
#   ./ops/scripts/cutover.sh --version v2.0.0
#   ./ops/scripts/cutover.sh --version v2.0.0 --from restore-staging
#
# This is the only script that moves production to v2. deploy-vps.sh never runs
# it and never reads its step file. The run is a sequence of named steps; each
# one is written to `cutover.step` before and after it runs, so a failure leaves
# the last step on disk and the operator chooses between `--from <step>` and
# `rollback.sh`. There is no automatic resume.
#
# The order is not negotiable: the v1 image is tagged and verified while v1 is
# still alive, because if the tag fails after v1 is stopped there is no way
# back.
#
# Env (in addition to MAJADU_APP_DIR):
#   MAJADU_OWNER_SUB     Google subject of the first platform owner (required)
#   MAJADU_OWNER_EMAIL   email of that account (optional)
#   MAJADU_CUTOVER_NETWORK  podman network shared with Postgres (default: qouver)
#   MAJADU_CADDY_CONFIG     main Caddyfile (default: /etc/caddy/Caddyfile)
#   MAJADU_SYSTEMCTL_CMD    systemctl invocation (default: systemctl --user)
#   MAJADU_CADDY_VALIDATE   Caddy check command (default: caddy validate)
#   MAJADU_STAGING_DB       database the dump is restored into (default: bm_staging)
#   MAJADU_BM2_DB           database the ETL writes to (default: bm2)
#   MAJADU_STEP_LOG         per-step timing log (default: <app>/cutover/cutover.timings.tsv)
#   MAJADU_TOOLS_ENV        tool DSN file (default: <app>/env/majadu-tools.env)
#
# The four DSNs come from the tool env, never from the file the API loads:
#   MAJADU_OWNER_DSN             bm2_owner on bm2 (DDL, migrations, state)
#   MAJADU_ETL_DSN               bm2_etl on bm2 (import target only)
#   MAJADU_ETL_SOURCE_DSN        a reader on bm_staging (import source only)
#   MAJADU_CUTOVER_RESTORE_DSN   a role that owns or can recreate bm_staging
#
# The *_CMD/*_VALIDATE overrides exist for the rehearsal harness (T-063), which
# runs the same sequence against a sandbox app dir and a rehearsal unit.
#
# `set -E` is what makes the ERR trap reach into the step functions: without it a
# failing step exits through set -e with no ERROR line, no step marker and no
# alert.
set -Eeuo pipefail

APP_DIR="${MAJADU_APP_DIR:-/srv/qouver/apps/majadu}"
SERVICE="${MAJADU_SERVICE:-majadu-api}"
LOCAL_IMAGE="${MAJADU_IMAGE:-localhost/majadu-api}"
REGISTRY_IMAGE="${MAJADU_REGISTRY_IMAGE:-ghcr.io/hidaydev/badminton-match}"
GITHUB_REPO="${MAJADU_GITHUB_REPO:-hidaydev/badminton-match}"
NETWORK="${MAJADU_CUTOVER_NETWORK:-qouver}"
CADDY_CONFIG="${MAJADU_CADDY_CONFIG:-/etc/caddy/Caddyfile}"
HEALTH_URL="${MAJADU_HEALTH_URL:-http://127.0.0.1:8080}"
CADDY_RELOAD="${MAJADU_CADDY_RELOAD:-sudo systemctl reload caddy}"
CADDY_VALIDATE="${MAJADU_CADDY_VALIDATE:-caddy validate}"
SYSTEMCTL="${MAJADU_SYSTEMCTL_CMD:-systemctl --user}"
STAGING_DB="${MAJADU_STAGING_DB:-bm_staging}"
BM2_DB="${MAJADU_BM2_DB:-bm2}"
CADDY_DIR="$APP_DIR/caddy"
CADDY_ACTIVE="$CADDY_DIR/active.caddy"
ENV_LINK="$APP_DIR/env/majadu-prod.env"
ENV_V1="$APP_DIR/env/majadu-prod.env.v1"
ENV_V2="$APP_DIR/env/majadu-prod.env.v2"
TOOLS_ENV="${MAJADU_TOOLS_ENV:-$APP_DIR/env/majadu-tools.env}"
MONO_DIR="$APP_DIR/monorepo"
CUTOVER_DIR="$APP_DIR/cutover"
LOCK_FILE="$APP_DIR/.deploy.lock"
STEP_FILE="$CUTOVER_DIR/cutover.step"
STEP_LOG="${MAJADU_STEP_LOG:-$CUTOVER_DIR/cutover.timings.tsv}"
LOG="$APP_DIR/logs/cutover.log"

STEPS=(preflight preserve-v1 maintenance stop-v1 snapshot restore-staging
  prepare-bm2 import state start site readyz smoke finish)

VERSION=""
FROM="preflight"
STEP="start"

mkdir -p "$CUTOVER_DIR" "$APP_DIR/logs" "$CADDY_DIR" "$APP_DIR/env"

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOG"
}

# The same sink deploy-vps.sh uses, so a cutover that stops halfway pages
# someone instead of waiting for the operator to notice. Silent when the
# template is not installed (a dev box or a rehearsal host without it) and it
# never blocks the failure path.
alert() {
  local unit="${MAJADU_ALERT_UNIT:-$(basename "$0" .sh)}"
  if $SYSTEMCTL list-unit-files 'majadu-alert@.service' >/dev/null 2>&1; then
    $SYSTEMCTL start "majadu-alert@$unit.service" >/dev/null 2>&1 || true
  fi
}

fail() {
  log "ERROR: $1 (step: $STEP)"
  printf '{"step":"%s","state":"failed","at":"%s"}\n' "$STEP" \
    "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" >"$STEP_FILE"
  log "last step: $STEP"
  log "resume with: $0 --version v$VERSION --from $STEP"
  log "or return to v1 with: $APP_DIR/scripts/rollback.sh"
  alert
  exit 1
}
trap 'fail "command failed at line $LINENO"' ERR

usage() {
  sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --version) shift; VERSION="${1:-}" ;;
    --from) shift; FROM="${1:-}" ;;
    -h|--help) usage; exit 0 ;;
    *) echo "cutover: unknown argument $1" >&2; exit 2 ;;
  esac
  shift
done

VERSION="${VERSION#v}"
if [ -z "$VERSION" ]; then
  VERSION=$(tr -d '[:space:]' <"$MONO_DIR/VERSION" 2>/dev/null || true)
fi
[ -n "$VERSION" ] || { echo "cutover: --version is required" >&2; exit 2; }

valid_step=0
for candidate in "${STEPS[@]}"; do
  if [ "$candidate" = "$FROM" ]; then
    valid_step=1
  fi
done
[ "$valid_step" -eq 1 ] || { echo "cutover: unknown step '$FROM'" >&2; exit 2; }

step_marker() {
  local at
  at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
  printf '{"step":"%s","state":"%s","at":"%s"}\n' "$STEP" "$1" "$at" >"$STEP_FILE"
  # The rehearsal harness (T-063) reads durations from this plain log; an
  # operator reads it when a step took longer than the runbook allows.
  printf '%s\t%s\t%s\t%s\n' "$STEP" "$1" "$(date +%s)" "$at" >>"$STEP_LOG"
}

env_value() {
  local file=$1 key=$2
  sed -n "s/^$key=//p" "$file" 2>/dev/null | tail -1
}

run_tool() {
  # The tools run from the release tag, not from :local: :local must keep
  # pointing at v1 until the switch, otherwise a crash restart before the
  # cutover would start v2 against the v1 database.
  local entry="$1" dsn="$2"
  shift 2
  podman run --rm --network "$NETWORK" -e MAJADU_PG_DSN="$dsn" \
    --entrypoint "$entry" "$LOCAL_IMAGE:release" "$@"
}

link_site() {
  local snippet="$1"
  ln -sfn "$CADDY_DIR/$snippet" "$CADDY_ACTIVE"
  $CADDY_VALIDATE --config "$CADDY_CONFIG" --adapter caddyfile >/dev/null
  $CADDY_RELOAD
  log "caddy now serves $snippet"
}

# ---------------------------------------------------------------------------
# Guards before anything is touched.
# ---------------------------------------------------------------------------
for tool in podman psql pg_dump pg_restore curl caddy flock; do
  command -v "$tool" >/dev/null 2>&1 || { echo "cutover: $tool is required" >&2; exit 2; }
done
[ -f "$ENV_V2" ] || { echo "cutover: $ENV_V2 is missing (the post-cutover env)" >&2; exit 2; }

# The tool DSNs live in a file the API unit never loads. The T-063 rehearsal
# sandbox installs a single v2 env, so when the tool file is absent the v2 env
# is read instead; a production host must have the tool file and fails closed
# below when a variable is missing from whichever file was chosen.
DSN_FILE="$TOOLS_ENV"
if [ ! -f "$TOOLS_ENV" ] && [ -f "$ENV_V2" ]; then
  DSN_FILE="$ENV_V2"
fi
if [ "$DSN_FILE" = "$ENV_V2" ]; then
  log "WARNING: $TOOLS_ENV is missing; reading tool DSNs from $ENV_V2 (rehearsal fallback)"
else
  log "tool DSNs from $DSN_FILE"
fi

if [ -f "$TOOLS_ENV" ]; then
  mode=$(stat -c '%a' "$TOOLS_ENV" 2>/dev/null || stat -f '%Lp' "$TOOLS_ENV" 2>/dev/null || echo "?")
  case "$mode" in
    600|400) ;;
    *) echo "cutover: $TOOLS_ENV must be mode 600 (found $mode)" >&2; exit 2 ;;
  esac
fi

missing_dsn() {
  echo "cutover: $1 is not set in $DSN_FILE" >&2
  exit 2
}

OWNER_DSN=$(env_value "$DSN_FILE" MAJADU_OWNER_DSN)
ETL_DSN=$(env_value "$DSN_FILE" MAJADU_ETL_DSN)
SOURCE_DSN=$(env_value "$DSN_FILE" MAJADU_ETL_SOURCE_DSN)
RESTORE_DSN=$(env_value "$DSN_FILE" MAJADU_CUTOVER_RESTORE_DSN)
[ -n "$OWNER_DSN" ] || missing_dsn MAJADU_OWNER_DSN
[ -n "$ETL_DSN" ] || missing_dsn MAJADU_ETL_DSN
[ -n "$SOURCE_DSN" ] || missing_dsn MAJADU_ETL_SOURCE_DSN
[ -n "$RESTORE_DSN" ] || missing_dsn MAJADU_CUTOVER_RESTORE_DSN
V1_DSN="${MAJADU_CUTOVER_V1_DSN:-postgresql:///bm}"

exec 9>"$LOCK_FILE"
if ! flock -w 900 9; then
  echo "cutover: another deploy or cutover holds the lock" >&2
  exit 1
fi

COMPLETED=$(psql "$OWNER_DSN" -Atc \
  "select coalesce(completed_at::text, '') from platform.cutover_state where id" \
  2>/dev/null || true)
if [ -n "$COMPLETED" ]; then
  log "already cut over at $COMPLETED; nothing to do"
  exit 0
fi

log "cutover v$VERSION starting from step '$FROM'"

# ---------------------------------------------------------------------------
# Steps.
# ---------------------------------------------------------------------------
step_preflight() {
  log "checking the release image"
  local auth=() token_mode
  if [ -f "$APP_DIR/env/ghcr-token" ]; then
    token_mode=$(stat -c '%a' "$APP_DIR/env/ghcr-token" 2>/dev/null || echo "?")
    case "$token_mode" in
      600|400) ;;
      *) fail "$APP_DIR/env/ghcr-token must be mode 600 (found $token_mode)" ;;
    esac
  fi
  if [ -f "$APP_DIR/env/ghcr-token" ]; then
    auth=(-H "Authorization: Bearer $(cat "$APP_DIR/env/ghcr-token")")
  fi
  local release digest markers marker_count strings string_count
  release=$(curl -fsS --max-time 20 -H "Accept: application/vnd.github+json" \
    "${auth[@]}" "https://api.github.com/repos/$GITHUB_REPO/releases/tags/v$VERSION" || true)
  markers=$(printf '%s' "$release" |
    grep -oE 'digest:[[:space:]]*sha256:[0-9a-f]{64}' || true)
  marker_count=$(printf '%s\n' "$markers" | grep -c 'sha256:' || true)
  strings=$(printf '%s' "$release" | grep -oE 'sha256:[0-9a-f]{64}' || true)
  string_count=$(printf '%s\n' "$strings" | grep -c 'sha256:' || true)
  [ "$marker_count" -ne 0 ] || fail "release v$VERSION has no published image digest"
  [ "$marker_count" -eq 1 ] && [ "$string_count" -eq 1 ] ||
    fail "release v$VERSION must carry exactly one 'digest: sha256:...' line (found $marker_count marker(s) and $string_count sha256 string(s))"
  digest="sha256:${markers#*sha256:}"
  local cosign_pub="$APP_DIR/env/cosign.pub"
  [ -f "$cosign_pub" ] || fail "release signature key $cosign_pub is missing; cannot verify $digest"
  command -v cosign >/dev/null 2>&1 || fail "cosign is required to verify $digest"
  cosign verify --key "$cosign_pub" "$REGISTRY_IMAGE@$digest" >>"$LOG" 2>&1 ||
    fail "cosign verify failed for $REGISTRY_IMAGE@$digest"
  if [ -f "$APP_DIR/env/ghcr-token" ]; then
    podman login ghcr.io -u "${MAJADU_GHCR_USER:-hidaydev}" --password-stdin \
      <"$APP_DIR/env/ghcr-token" >>"$LOG" 2>&1
  fi
  podman pull "$REGISTRY_IMAGE@$digest" >>"$LOG" 2>&1 ||
    fail "cannot pull $REGISTRY_IMAGE@$digest"
  podman tag "$REGISTRY_IMAGE@$digest" "$LOCAL_IMAGE:release"
  printf '%s\n' "$digest" >"$CUTOVER_DIR/release.digest"

  install -m 644 "$MONO_DIR/ops/caddy/site-v1.caddy" "$CADDY_DIR/site-v1.caddy"
  install -m 644 "$MONO_DIR/ops/caddy/site-v2.caddy" "$CADDY_DIR/site-v2.caddy"
  install -m 644 "$MONO_DIR/ops/caddy/site-maintenance.caddy" "$CADDY_DIR/site-maintenance.caddy"
  [ -e "$CADDY_ACTIVE" ] || ln -s "$CADDY_DIR/site-v1.caddy" "$CADDY_ACTIVE"
  [ -e "$ENV_LINK" ] || ln -s "$ENV_V1" "$ENV_LINK"

  # Share codes and websocket tickets travel in the query string, so the log
  # matcher has to cover both prefixes. A matcher that only names /majadu/s/*
  # writes live tickets into the access log of the whole server.
  if [ -f "$CADDY_CONFIG" ]; then
    if grep -q '/majadu/s/\*' "$CADDY_CONFIG" &&
      ! grep -q '/majadu/ws/\*' "$CADDY_CONFIG"; then
      fail "$CADDY_CONFIG skips /majadu/s/* but not /majadu/ws/* in the log matcher; see ops/caddy/Caddyfile.api.qouver.com step 3"
    fi
  fi
}

step_preserve_v1() {
  # The running container, not a guess: whatever v1 is executing right now is
  # what rollback must be able to start again.
  local running
  running=$(podman inspect --format '{{.Image}}' "$SERVICE")
  [ -n "$running" ] || fail "cannot read the running v1 image"

  if podman image exists "$LOCAL_IMAGE:v1-final"; then
    local recorded now
    recorded=$(cat "$CUTOVER_DIR/v1-final.digest" 2>/dev/null || true)
    now=$(podman image inspect --format '{{.Id}}' "$LOCAL_IMAGE:v1-final")
    if [ -n "$recorded" ] && [ "$recorded" != "$now" ]; then
      fail ":v1-final was replaced (recorded $recorded, found $now)"
    fi
    log ":v1-final already exists; leaving it alone"
  else
    podman tag "$running" "$LOCAL_IMAGE:v1-final"
    podman image inspect --format '{{.Id}}' "$LOCAL_IMAGE:v1-final" \
      >"$CUTOVER_DIR/v1-final.digest"
    log "tagged the running v1 image as :v1-final"
  fi
  [ "$(podman image inspect --format '{{.Id}}' "$LOCAL_IMAGE:v1-final")" = "$running" ] ||
    fail ":v1-final does not match the running image"

  # The unit and env that v1 used are restored verbatim by rollback.sh.
  cp -f "$HOME/.config/containers/systemd/$SERVICE.container" \
    "$CUTOVER_DIR/$SERVICE.container.v1" 2>/dev/null || true
  if [ -L "$ENV_LINK" ]; then
    readlink -f "$ENV_LINK" >"$CUTOVER_DIR/env-target.v1"
  fi
}

step_maintenance() {
  link_site site-maintenance.caddy
}

step_stop_v1() {
  $SYSTEMCTL stop "$SERVICE"
  # disable, not just stop: a reboot must not bring v1 back and write to bm.
  $SYSTEMCTL disable "$SERVICE" >/dev/null 2>&1 || true
  log "v1 is stopped and disabled"
}

step_snapshot() {
  log "dumping bm for the import"
  MAJADU_APP_DIR="$APP_DIR" \
    MAJADU_BACKUP_DSN_BM="$V1_DSN" \
    "$APP_DIR/scripts/backup.sh" --tag cutover
  local dump
  dump=$(ls -t "$APP_DIR"/backups/bm-cutover-*.dump 2>/dev/null | head -1 || true)
  [ -n "$dump" ] || fail "no cutover dump was written"
  printf '%s\n' "$dump" >"$CUTOVER_DIR/snapshot.path"
  sha256sum "$dump" | cut -d' ' -f1 >"$CUTOVER_DIR/snapshot.sha256"
  date -u '+%Y-%m-%dT%H:%M:%SZ' >"$CUTOVER_DIR/snapshot.taken_at"
  log "snapshot $(cat "$CUTOVER_DIR/snapshot.sha256")"
}

step_restore_staging() {
  local dump
  dump=$(cat "$CUTOVER_DIR/snapshot.path")
  # The ETL role cannot drop or create bm_staging, so the restore uses its own
  # DSN: a role that owns the staging database or has CREATEDB.
  "$APP_DIR/scripts/restore.sh" --file "$dump" --target "$STAGING_DB" \
    --dsn "$RESTORE_DSN" --recreate
}

step_prepare_bm2() {
  log "preparing bm2"
  psql "$OWNER_DSN" -v ON_ERROR_STOP=1 -v db="$BM2_DB" \
    -f "$MONO_DIR/ops/db/roles.sql" >>"$LOG" 2>&1

  set_role_password() {
    local role="$1" password="$2"
    printf "alter role %s with login password '%s';\n" \
      "$role" "${password//\'/\'\'}" |
      psql "$OWNER_DSN" -v ON_ERROR_STOP=1 >>"$LOG" 2>&1
  }
  [ -n "${BM2_OWNER_PASSWORD:-}" ] && set_role_password bm2_owner "$BM2_OWNER_PASSWORD"
  [ -n "${BM2_APP_PASSWORD:-}" ] && set_role_password bm2_app "$BM2_APP_PASSWORD"
  [ -n "${BM2_ETL_PASSWORD:-}" ] && set_role_password bm2_etl "$BM2_ETL_PASSWORD"

  run_tool /usr/local/bin/dbtools "$OWNER_DSN" \
    migrate --dir /app/db/migrations >>"$LOG" 2>&1
  run_tool /usr/local/bin/dbtools "$OWNER_DSN" \
    seed --dir /app/db/seeds >>"$LOG" 2>&1

  local owner_sub="${MAJADU_OWNER_SUB:-}"
  [ -n "$owner_sub" ] || fail "MAJADU_OWNER_SUB is required to bootstrap the owner"
  run_tool /usr/local/bin/ownerseed "$OWNER_DSN" --sub "$owner_sub" \
    ${MAJADU_OWNER_EMAIL:+--email "$MAJADU_OWNER_EMAIL"} >>"$LOG" 2>&1
}

step_import() {
  log "importing bm_staging into bm2"
  run_tool /usr/local/bin/majadu-import "$ETL_DSN" \
    etl --source "$SOURCE_DSN" --target "$ETL_DSN" --slug majadu --name Majadu \
    >>"$LOG" 2>&1
  run_tool /usr/local/bin/majadu-import "$ETL_DSN" \
    verify --source "$SOURCE_DSN" --target "$ETL_DSN" --slug majadu \
    >>"$LOG" 2>&1
}

step_state() {
  local snapshot taken_at etl_at rows
  snapshot=$(cat "$CUTOVER_DIR/snapshot.sha256")
  taken_at=$(cat "$CUTOVER_DIR/snapshot.taken_at")
  etl_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
  rows=$(psql "$OWNER_DSN" -Atc """
    select json_build_object(
      'players', (select count(*) from player.players),
      'sessions', (select count(*) from session.sessions),
      'games', (select count(*) from session.games),
      'tournaments', (select count(*) from tournament.tournaments),
      'achievements', (select count(*) from achievement.earned),
      'ratingEvents', (select count(*) from rating.events))::text""")
  psql "$OWNER_DSN" -v ON_ERROR_STOP=1 -v sha="$snapshot" -v version="$VERSION" \
    -v rows="$rows" -v etl="$etl_at" -v taken="$taken_at" >>"$LOG" 2>&1 <<'SQL'
insert into platform.cutover_state
  (id, snapshot_sha256, snapshot_taken_at, etl_completed_at, app_version, rows_imported)
values (true, :'sha', :'taken'::timestamptz, :'etl'::timestamptz, :'version', :'rows'::jsonb)
on conflict (id) do update set
  snapshot_sha256 = excluded.snapshot_sha256,
  snapshot_taken_at = excluded.snapshot_taken_at,
  etl_completed_at = excluded.etl_completed_at,
  app_version = excluded.app_version,
  rows_imported = excluded.rows_imported;
SQL

  # The API refuses to be ready on the wrong snapshot, so the env carries it.
  if grep -q '^CUTOVER_SNAPSHOT_SHA256=' "$ENV_V2"; then
    sed -i "s|^CUTOVER_SNAPSHOT_SHA256=.*|CUTOVER_SNAPSHOT_SHA256=$snapshot|" "$ENV_V2"
  else
    printf 'CUTOVER_SNAPSHOT_SHA256=%s\n' "$snapshot" >>"$ENV_V2"
  fi
  chmod 600 "$ENV_V2"
  ln -sfn "$ENV_V2" "$ENV_LINK"
  log "env now points at v2"
}

step_site() {
  # Caddy moves only after the process answers on localhost, so the site is
  # never pointed at a port that nothing is listening on.
  link_site site-v2.caddy
}

step_start() {
  podman tag "$LOCAL_IMAGE:release" "$LOCAL_IMAGE:local"
  $SYSTEMCTL enable "$SERVICE" >/dev/null 2>&1
  $SYSTEMCTL restart "$SERVICE"
}

step_readyz() {
  local deadline=$((SECONDS + 90))
  while [ "$SECONDS" -lt "$deadline" ]; do
    if curl -fsS --max-time 3 $HEALTH_URL/readyz >/dev/null 2>&1; then
      log "/readyz is green"
      return 0
    fi
    sleep 2
  done
  fail "/readyz did not become green within 90s"
}

step_smoke() {
  "$APP_DIR/scripts/smoke.sh" "$HEALTH_URL" "$VERSION"
}

step_finish() {
  psql "$OWNER_DSN" -v ON_ERROR_STOP=1 \
    -c "update platform.cutover_state set completed_at = now() where id" \
    >>"$LOG" 2>&1
  log "cutover v$VERSION complete"
}

# ---------------------------------------------------------------------------
# Runner.
# ---------------------------------------------------------------------------
STARTED=0
for STEP in "${STEPS[@]}"; do
  if [ "$STARTED" -eq 0 ]; then
    [ "$STEP" = "$FROM" ] && STARTED=1 || continue
  fi
  step_marker begin
  "step_${STEP//-/_}"
  step_marker end
done

log "cutover sequence finished"
