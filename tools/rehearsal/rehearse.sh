#!/usr/bin/env bash
# Rehearse the cutover on a sandbox app dir, then time every step.
#
#   tools/rehearsal/rehearse.sh run [--version v2.0.0] [--dry-run]
#                                   [--no-from-proof]
#   tools/rehearsal/rehearse.sh clean
#   tools/rehearsal/rehearse.sh check      # gate: reads timings.json only
#
# The runner is deliberately not part of CI: it needs Podman, a real Caddy, a
# systemd user session, two rehearsal databases and an announced maintenance
# window. It never touches the production app dir, service, Caddy site or
# database names; those are guarded below.
#
# What it proves: the same cutover.sh sequence against a sandbox unit and a
# sandbox Caddy site, on a clone of bm_staging, then a rollback back to a v1
# image. What it writes: tools/rehearsal/timings.json with per-step seconds and
# the three budgets from T-063.
#
# Prerequisites (one-time, on the VPS):
#   - roles and databases: bm2_rehearsal, bm_staging (a copy of a real staging
#     database), and bm2_rehearsal owned by bm2_owner (ops/db/roles.sql does it)
#   - $MAJADU_REHEARSAL_ENV_DIR/v1.env and v2.env, mode 600, from the templates
#     in ops/env/rehearsal-v{1,2}.env.example
#   - a published release with an image digest (cutover preflight pulls it)
set -euo pipefail

# shellcheck disable=SC1007 # CDPATH= is how the repo clears CDPATH before cd.
REPO_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
TIMINGS="$REPO_ROOT/tools/rehearsal/timings.json"
SANDBOX="${MAJADU_REHEARSAL_DIR:-${TMPDIR:-/tmp}/majadu-rehearsal}"
ENV_DIR="${MAJADU_REHEARSAL_ENV_DIR:-$SANDBOX/env}"
ADMIN_DSN="${MAJADU_REHEARSAL_ADMIN_DSN:-postgresql:///postgres}"
SERVICE=majadu-rehearsal
IMAGE=localhost/majadu-api-rehearsal
APP_PORT=18080
SITE_PORT=18081
CADDY_ADMIN=127.0.0.1:2020
STAGING_DB=bm_staging
BM2_DB=bm2_rehearsal
V1_DB=bm_staging
UNIT_DIR="$HOME/.config/containers/systemd"

# Budgets from T-063: the whole rehearsal, the restore step, and the window in
# which users are actually redirected to maintenance.
BUDGET_TOTAL=1800
BUDGET_RESTORE=900
BUDGET_WINDOW=600

usage() {
  sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'
}

fail() {
  printf 'rehearsal: %s\n' "$1" >&2
  exit 1
}

mode=${1:-run}
if [ "$#" -gt 0 ]; then
  shift
fi

case "$mode" in
  -h|--help|help) usage; exit 0 ;;
esac

# ---------------------------------------------------------------------------
# check: the gate. No host tooling, no Podman - it only reads the committed
# timings, so it can run anywhere, including before a cutover.
# ---------------------------------------------------------------------------
num_field() {
  sed -n "s/^  \"$1\": \([0-9][0-9]*\),$/\1/p" "$TIMINGS" | head -1
}

check() {
  [ -f "$TIMINGS" ] || fail "missing $(basename "$TIMINGS")"
  local status total restore window rollback recorded budget_total budget_restore budget_window age
  status=$(sed -n 's/^  "status": "\([a-z_]*\)",$/\1/p' "$TIMINGS" | head -1)
  total=$(num_field total_seconds)
  restore=$(num_field restore_seconds)
  window=$(num_field window_seconds)
  rollback=$(num_field rollback_seconds)
  recorded=$(num_field recorded_epoch)
  budget_total=$(num_field budget_total)
  budget_restore=$(num_field budget_restore)
  budget_window=$(num_field budget_window)

  if [ "$status" != "passed" ]; then
    printf 'rehearsal: last run is "%s"; run rehearse.sh run and commit timings.json\n' \
      "${status:-missing}" >&2
    exit 1
  fi

  resume=$(sed -nE 's/^  "resume_proof": (true|false),$/\1/p' "$TIMINGS" | head -1)
  if [ "$resume" != "true" ]; then
    printf 'rehearsal: --from was not proven in the last run; repeat it with the resume proof\n' >&2
    exit 1
  fi

  age=$(( $(date +%s) - ${recorded:-0} ))
  if [ "$age" -gt $((14 * 86400)) ]; then
    printf 'rehearsal: last passing run is %s days old; rehearse again before the window\n' \
      "$((age / 86400))" >&2
    exit 1
  fi

  local bad=0
  budget() {
    if [ "$2" -gt "$3" ]; then
      printf 'rehearsal: %s %ss over budget %ss\n' "$1" "$2" "$3" >&2
      bad=1
    fi
  }
  budget "total" "$total" "${budget_total:-$BUDGET_TOTAL}"
  budget "restore" "$restore" "${budget_restore:-$BUDGET_RESTORE}"
  budget "cutover window" "$window" "${budget_window:-$BUDGET_WINDOW}"
  [ "$bad" -eq 0 ] || exit 1

  printf 'rehearsal: ok (total %ss, restore %ss, window %ss, rollback %ss)\n' \
    "$total" "$restore" "$window" "$rollback"
}

# ---------------------------------------------------------------------------
# clean: remove everything run left behind. Databases are dropped only with
# --drop-databases, because a rehearsal database may be the only copy of the
# staging snapshot on that host.
# ---------------------------------------------------------------------------
clean() {
  local drop=0
  [ "${1:-}" = "--drop-databases" ] && drop=1

  if [ -f "$UNIT_DIR/$SERVICE.container" ]; then
    systemctl --user stop "$SERVICE" >/dev/null 2>&1 || true
    rm -f "$UNIT_DIR/$SERVICE.container"
    systemctl --user daemon-reload
    printf 'rehearsal: removed the %s unit\n' "$SERVICE"
  fi
  podman image rm -f "$IMAGE:local" "$IMAGE:release" "$IMAGE:v1-final" \
    >/dev/null 2>&1 || true
  [ -d "$SANDBOX" ] && rm -rf "$SANDBOX" && printf 'rehearsal: removed %s\n' "$SANDBOX"

  if [ "$drop" -eq 1 ]; then
    dropdb --if-exists "$BM2_DB" >/dev/null 2>&1 || true
    printf 'rehearsal: dropped %s\n' "$BM2_DB"
  fi
}

# ---------------------------------------------------------------------------
# run
# ---------------------------------------------------------------------------
case "$mode" in
  check) check; exit 0 ;;
  clean) clean "$@"; exit 0 ;;
  run) ;;
  *) fail "unknown mode $mode (use run, clean or check)" ;;
esac

VERSION=""
DRY_RUN=0
FROM_PROOF=1
while [ "$#" -gt 0 ]; do
  case "$1" in
    --version) shift; VERSION="${1:-}" ;;
    --dry-run) DRY_RUN=1 ;;
    --no-from-proof) FROM_PROOF=0 ;;
    *) fail "unknown argument $1" ;;
  esac
  shift
done
VERSION="${VERSION#v}"
if [ -z "$VERSION" ]; then
  VERSION=$(tr -d '[:space:]' <"$REPO_ROOT/VERSION" 2>/dev/null || true)
fi
[ -n "$VERSION" ] || fail "--version is required (or set VERSION in the repository)"

for file in "$ENV_DIR/v1.env" "$ENV_DIR/v2.env"; do
  [ -f "$file" ] || fail "missing $file (copy the template from ops/env/)"
  mode_bits=$(stat -c '%a' "$file" 2>/dev/null || stat -f '%Lp' "$file")
  case "$mode_bits" in
    600|400) ;;
    *) fail "$file must be mode 600 (found $mode_bits)" ;;
  esac
done

# The env file decides which database the rehearsal writes to, so the guard is
# on its content: a rehearsal must never point at bm, bm2 or bm2_dev.
for file in "$ENV_DIR/v1.env" "$ENV_DIR/v2.env"; do
  if grep -Eq '@[^/]*/(bm|bm2|bm2_dev|postgres)([?"'"'"' ]|$)' "$file"; then
    fail "$file points at a protected database"
  fi
done

grep -q "^MAJADU_PG_DSN=.*/$BM2_DB" "$ENV_DIR/v2.env" ||
  fail "$ENV_DIR/v2.env must set MAJADU_PG_DSN to $BM2_DB"
for key in MAJADU_OWNER_DSN MAJADU_ETL_DSN MAJADU_ETL_SOURCE_DSN \
  MAJADU_CUTOVER_RESTORE_DSN; do
  grep -q "^$key=" "$ENV_DIR/v2.env" || fail "$ENV_DIR/v2.env is missing $key"
done

printf 'rehearsal: preparing %s for v%s\n' "$SANDBOX" "$VERSION"
mkdir -p "$SANDBOX/app"/{env,caddy,logs,cutover,backups} "$SANDBOX/home"
ln -sfn "$REPO_ROOT" "$SANDBOX/app/monorepo"
ln -sfn "$REPO_ROOT/ops/scripts" "$SANDBOX/app/scripts"
install -m 600 "$ENV_DIR/v1.env" "$SANDBOX/app/env/majadu-prod.env.v1"
install -m 600 "$ENV_DIR/v2.env" "$SANDBOX/app/env/majadu-prod.env.v2"
ln -sfn "$SANDBOX/app/env/majadu-prod.env.v1" "$SANDBOX/app/env/majadu-prod.env"
for snippet in site-v1 site-v2 site-maintenance; do
  install -m 644 "$REPO_ROOT/ops/caddy/$snippet.caddy" "$SANDBOX/app/caddy/$snippet.caddy"
done
ln -sfn "$SANDBOX/app/caddy/site-v1.caddy" "$SANDBOX/app/caddy/active.caddy"

# Sandbox Caddy: its own site, its own admin port, so a reload here cannot
# touch the production Caddyfile.
cat >"$SANDBOX/app/Caddyfile.rehearsal" <<EOF
{
	admin $CADDY_ADMIN
	auto_https off
}

http://127.0.0.1:$SITE_PORT {
	import $SANDBOX/app/caddy/active.caddy
	handle {
		respond "not found" 404
	}
}
EOF

# Rehearsal unit: the production file with the container name, image, port,
# env path and volume swapped, and the alert dropped so a failed rehearsal does
# not page anyone.
sed -e "s|^Image=.*|Image=$IMAGE:local|" \
    -e "s|^ContainerName=.*|ContainerName=$SERVICE|" \
    -e "s|^PublishPort=.*|PublishPort=127.0.0.1:$APP_PORT:8080|" \
    -e "s|^EnvironmentFile=.*|EnvironmentFile=$SANDBOX/app/env/majadu-prod.env|" \
    -e "s|^Volume=.*|Volume=$SANDBOX/app/logs/main:/logs:Z|" \
    -e "/^OnFailure=/d" \
    "$REPO_ROOT/ops/systemd/majadu-api.container" \
    >"$SANDBOX/$SERVICE.container"

CUTOVER_ENV=(
  "MAJADU_APP_DIR=$SANDBOX/app"
  "MAJADU_SERVICE=$SERVICE"
  "MAJADU_IMAGE=$IMAGE"
  "MAJADU_HEALTH_URL=http://127.0.0.1:$APP_PORT"
  "MAJADU_CADDY_CONFIG=$SANDBOX/app/Caddyfile.rehearsal"
  "MAJADU_CADDY_RELOAD=caddy reload --address $CADDY_ADMIN --config $SANDBOX/app/Caddyfile.rehearsal --adapter caddyfile"
  "MAJADU_STAGING_DB=$STAGING_DB"
  "MAJADU_BM2_DB=$BM2_DB"
  "MAJADU_CUTOVER_V1_DSN=postgresql:///$V1_DB"
  "MAJADU_OWNER_SUB=${MAJADU_OWNER_SUB:-rehearsal-owner}"
  # A failed rehearsal still pages someone, but the alert must not read as a
  # failed production cutover (cutover.sh defaults the unit to its own name).
  "MAJADU_ALERT_UNIT=rehearsal"
)

if [ "$DRY_RUN" -eq 1 ]; then
  printf 'rehearsal: dry run, nothing was executed. Would run:\n\n'
  printf '  psql %s -c "drop database if exists %s with (force)"\n' "$ADMIN_DSN" "$BM2_DB"
  printf '  createdb %s && psql %s -f %s/ops/db/roles.sql -v db=%s\n' "$BM2_DB" "$BM2_DB" "$REPO_ROOT" "$BM2_DB"
  printf '  install -m 644 %s %s/%s.container && systemctl --user daemon-reload\n' \
    "$SANDBOX/$SERVICE.container" "$UNIT_DIR" "$SERVICE"
  printf '  caddy run --config %s --adapter caddyfile &\n' "$SANDBOX/app/Caddyfile.rehearsal"
  printf '  podman tag localhost/majadu-api:v1-final %s:v1-final && podman tag %s:v1-final %s:local\n' \
    "$IMAGE" "$IMAGE" "$IMAGE"
  printf '  systemctl --user enable --now %s   # v1 must be running before the cutover preserves it\n' "$SERVICE"
  printf '  env %s \\\n' "${CUTOVER_ENV[*]}"
  printf '    %s/../scripts/cutover.sh --version v%s\n' "$REPO_ROOT/ops" "$VERSION"
  printf '  env %s \\\n' "${CUTOVER_ENV[*]}"
  printf '    %s/../scripts/rollback.sh\n' "$REPO_ROOT/ops"
  printf '\nSandbox assembled at %s. Move bm_staging in place first:\n' "$SANDBOX"
  printf '  createdb -T <source> %s\n' "$STAGING_DB"
  exit 0
fi

for tool in podman psql createdb dropdb curl flock caddy; do
  command -v "$tool" >/dev/null 2>&1 || fail "$tool is required for run"
done

[ "${MAJADU_REHEARSAL_CONFIRM:-}" = "yes" ] ||
  fail "set MAJADU_REHEARSAL_CONFIRM=yes after announcing the maintenance window"

# --- databases ------------------------------------------------------------
printf 'rehearsal: recreating %s and %s\n' "$BM2_DB" "$STAGING_DB"
psql "$ADMIN_DSN" -v ON_ERROR_STOP=1 -c "drop database if exists $BM2_DB with (force)" >/dev/null
psql "$ADMIN_DSN" -v ON_ERROR_STOP=1 -c "create database $BM2_DB" >/dev/null
[ "$(psql "$ADMIN_DSN" -Atc \
  "select 1 from pg_database where datname = '$STAGING_DB'")" = "1" ] ||
  fail "$STAGING_DB does not exist; restore a staging dump into it first"
psql "$ADMIN_DSN" -v ON_ERROR_STOP=1 -d "$BM2_DB" -v db="$BM2_DB" \
  -f "$REPO_ROOT/ops/db/roles.sql" >/dev/null

# --- unit and caddy -------------------------------------------------------
install -m 644 "$SANDBOX/$SERVICE.container" "$UNIT_DIR/$SERVICE.container"
systemctl --user daemon-reload

caddy_pid=""
cleanup() {
  if [ -n "$caddy_pid" ]; then
    kill "$caddy_pid" 2>/dev/null || true
    wait "$caddy_pid" 2>/dev/null || true
  fi
}
trap cleanup EXIT

caddy run --config "$SANDBOX/app/Caddyfile.rehearsal" --adapter caddyfile \
  >"$SANDBOX/caddy.log" 2>&1 &
caddy_pid=$!
waited=0
while [ "$waited" -lt 100 ]; do
  if curl -s -o /dev/null --max-time 1 "http://127.0.0.1:$SITE_PORT/healthz"; then
    break
  fi
  sleep 0.1
  waited=$((waited + 1))
done

# --- v1 must be running ---------------------------------------------------
# cutover.sh tags the *running* container as :v1-final; without a running
# rehearsal container the preserve step has nothing to preserve. The production
# :v1-final image is reused when it exists, otherwise today's :local (which is
# still v1 before the first real cutover).
printf 'rehearsal: starting the v1 image the cutover will preserve\n'
if podman image exists localhost/majadu-api:v1-final; then
  podman tag localhost/majadu-api:v1-final "$IMAGE:v1-final"
else
  printf 'rehearsal: localhost/majadu-api:v1-final is absent; using localhost/majadu-api:local as v1\n'
  podman tag localhost/majadu-api:local "$IMAGE:v1-final"
fi
podman tag "$IMAGE:v1-final" "$IMAGE:local"
systemctl --user enable "$SERVICE" >/dev/null 2>&1 || true
systemctl --user restart "$SERVICE"
waited=0
while [ "$waited" -lt 300 ]; do
  if curl -fsS --max-time 2 "http://127.0.0.1:$APP_PORT/healthz" >/dev/null 2>&1; then
    break
  fi
  sleep 0.2
  waited=$((waited + 1))
done
curl -fsS --max-time 2 "http://127.0.0.1:$APP_PORT/healthz" >/dev/null ||
  fail "the v1 rehearsal unit did not answer /healthz on :$APP_PORT"

# --- cutover --------------------------------------------------------------
printf 'rehearsal: running the cutover\n'
started=$(date +%s)
cutover_ok=0
if env "${CUTOVER_ENV[@]}" "$REPO_ROOT/ops/scripts/cutover.sh" --version "v$VERSION"; then
  cutover_ok=1
fi
finished=$(date +%s)

# Per-step seconds from the log cutover.sh writes next to its step marker.
steps_json=$(
  awk -F'\t' '
    $2 == "begin" { begin[$1] = $3 }
    $2 == "end" && ($1 in begin) { printf "%s\"%s\": %d", (n++ ? ", " : ""), $1, $3 - begin[$1] }
  ' "$SANDBOX/app/cutover/cutover.timings.tsv" 2>/dev/null || true
)
total=$((finished - started))
restore=$(awk -F'\t' '$1 == "restore-staging" && $2 == "begin" { b = $3 } $1 == "restore-staging" && $2 == "end" { print $3 - b }' \
  "$SANDBOX/app/cutover/cutover.timings.tsv" 2>/dev/null | head -1)
window=$(awk -F'\t' '
  $1 == "maintenance" && $2 == "begin" { b = $3 }
  $1 == "readyz" && $2 == "end" { print $3 - b }
' "$SANDBOX/app/cutover/cutover.timings.tsv" 2>/dev/null | head -1)
restore=${restore:-0}
window=${window:-0}

# The sandbox site must answer through Caddy, not just on the app port.
site_ok=0
if body=$(curl -sS --max-time 5 "http://127.0.0.1:$SITE_PORT/version" 2>/dev/null) &&
   printf '%s' "$body" | grep -q "\"version\":\"$VERSION\""; then
  site_ok=1
fi

# --- rollback -------------------------------------------------------------
printf 'rehearsal: running the rollback\n'
rollback_started=$(date +%s)
rollback_ok=0
# --abandon-data: the sandbox rows written during the window are the thing this
# rehearsal throws away on purpose.
if env "${CUTOVER_ENV[@]}" "$REPO_ROOT/ops/scripts/rollback.sh" --abandon-data; then
  rollback_ok=1
fi
rollback_seconds=$(( $(date +%s) - rollback_started ))

# --- --from proof ---------------------------------------------------------
# rollback.sh removes cutover_state, so `--from restore-staging` runs the tail
# of the sequence again on the artefacts the first pass left behind. That is the
# only automated way to prove resume without faking a failure mid-run.
resume_proof=false
resume_seconds=0
if [ "$FROM_PROOF" -eq 1 ] && [ "$cutover_ok" -eq 1 ] && [ "$rollback_ok" -eq 1 ]; then
  printf 'rehearsal: proving --from restore-staging\n'
  resume_started=$(date +%s)
  if env "${CUTOVER_ENV[@]}" "$REPO_ROOT/ops/scripts/cutover.sh" \
    --version "v$VERSION" --from restore-staging; then
    resume_proof=true
    # Leave the sandbox on v1 again so a second run starts from the same place.
    env "${CUTOVER_ENV[@]}" "$REPO_ROOT/ops/scripts/rollback.sh" \
      --abandon-data || resume_proof=false
  fi
  resume_seconds=$(( $(date +%s) - resume_started ))
fi

# --- verdict and timings --------------------------------------------------
status=failed
[ "$cutover_ok" -eq 1 ] && [ "$rollback_ok" -eq 1 ] && [ "$site_ok" -eq 1 ] &&
  [ "$resume_proof" = "true" ] &&
  [ "$total" -le "$BUDGET_TOTAL" ] && [ "$restore" -le "$BUDGET_RESTORE" ] &&
  [ "$window" -le "$BUDGET_WINDOW" ] && status=passed

cat >"$TIMINGS" <<EOF
{
  "status": "$status",
  "recorded": "$(date -u '+%Y-%m-%d')",
  "recorded_epoch": $(date +%s),
  "host": "$(hostname)",
  "version": "$VERSION",
  "budget_total": $BUDGET_TOTAL,
  "budget_restore": $BUDGET_RESTORE,
  "budget_window": $BUDGET_WINDOW,
  "total_seconds": $total,
  "restore_seconds": $restore,
  "window_seconds": $window,
  "rollback_seconds": $rollback_seconds,
  "resume_proof": $resume_proof,
  "resume_seconds": $resume_seconds,
  "steps": {$steps_json},
  "notes": "sandbox app dir, rehearsal unit and sandbox Caddy; bm_staging -> $BM2_DB"
}
EOF

printf '\n%-22s %8s\n' step seconds
awk -F'\t' '
  $2 == "begin" { begin[$1] = $3 }
  $2 == "end" && ($1 in begin) { printf "%-22s %8d\n", $1, $3 - begin[$1] }
' "$SANDBOX/app/cutover/cutover.timings.tsv" 2>/dev/null || true
printf '%s\n' "-----------------------------"
printf '%-22s %8d (budget %d)\n' total "$total" "$BUDGET_TOTAL"
printf '%-22s %8d (budget %d)\n' restore "$restore" "$BUDGET_RESTORE"
printf '%-22s %8d (budget %d)\n' "cutover window" "$window" "$BUDGET_WINDOW"
printf '%-22s %8d\n' rollback "$rollback_seconds"
printf '%-22s %8s %8d\n' "--from proof" "$resume_proof" "$resume_seconds"
printf '\nrehearsal: %s; timings written to %s\n' "$status" "${TIMINGS#$REPO_ROOT/}"
[ "$status" = "passed" ] || exit 1
