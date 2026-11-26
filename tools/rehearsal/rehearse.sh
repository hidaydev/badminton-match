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
#   - a v1 image the rollback can restore: $MAJADU_REHEARSAL_V1_IMAGE, default
#     localhost/majadu-api:v1-final. It is never guessed from :local, because
#     :local is v2 after the first real cutover.
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
STAGING_DB=bm_restore_rehearsal
BM2_DB=bm2_rehearsal
# The v1 side needs a database it can read but must never be the thing the
# restore overwrites: in production the dump comes from `bm` and is restored
# into bm_staging. Here the dump comes from the real bm_staging, read-only, and
# is restored into a throwaway the restore allow-list already accepts
# (`bm_restore_*`), so no production-named database is ever written.
V1_DB=bm_staging
V1_DSN="postgresql://qouver@127.0.0.1:5432/$V1_DB"
UNIT_DIR="$HOME/.config/containers/systemd"

# Budgets from T-063: the whole rehearsal, the restore step, and the window in
# which users are actually redirected to maintenance.
BUDGET_TOTAL=1800
BUDGET_RESTORE=900
BUDGET_WINDOW=600

# Database client: host binaries when present, otherwise the PostgreSQL
# container, the route cutover.sh, rollback.sh, restore.sh and backup.sh
# already take. The documented host carries no psql/createdb/dropdb, so a
# rehearsal that insists on them cannot run there at all.
PG_CONTAINER="${MAJADU_PG_CONTAINER:-qouver-postgres}"
USE_CONTAINER=0
for tool in psql createdb dropdb; do
  command -v "$tool" >/dev/null 2>&1 || USE_CONTAINER=1
done

# Inside the container the client runs as root, and the image's superuser is a
# different role on every host (qouver1 uses `qouver`, a dev box uses
# `postgres`), so the role is read from the container instead of assumed. A
# user named in the DSN still wins: libpq prefers the connection string.
PGUSER_VALUE=""
PGUSERS=()
if [ "$USE_CONTAINER" -eq 1 ]; then
  PGUSER_VALUE="${MAJADU_REHEARSAL_PGUSER:-}"
  if [ -z "$PGUSER_VALUE" ]; then
    PGUSER_VALUE=$(podman inspect --format '{{range .Config.Env}}{{println .}}{{end}}' \
      "$PG_CONTAINER" 2>/dev/null | sed -n 's/^POSTGRES_USER=//p' | head -1)
  fi
  [ -n "$PGUSER_VALUE" ] && PGUSERS=(-e "PGUSER=$PGUSER_VALUE")
fi

psql_cmd() {
  if [ "$USE_CONTAINER" -eq 1 ]; then
    podman exec -i "${PGUSERS[@]}" "$PG_CONTAINER" psql "$@"
  else
    psql "$@"
  fi
}

dropdb_cmd() {
  if [ "$USE_CONTAINER" -eq 1 ]; then
    podman exec -i "${PGUSERS[@]}" "$PG_CONTAINER" dropdb "$@"
  else
    dropdb "$@"
  fi
}

pg_dump_cmd() {
  if [ "$USE_CONTAINER" -eq 1 ]; then
    podman exec "${PGUSERS[@]}" "$PG_CONTAINER" pg_dump "$@"
  else
    pg_dump "$@"
  fi
}

# The image the cutover preserves and rollback.sh restores. It has to be named
# explicitly rather than falling back to :local: after the first cutover :local
# is v2, so that fallback rolls v2 back onto itself and records a rollback
# proof that means nothing.
V1_IMAGE="${MAJADU_REHEARSAL_V1_IMAGE:-localhost/majadu-api:v1-final}"

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
    dropdb_cmd --if-exists "$BM2_DB" >/dev/null 2>&1 || true
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
# cutover.sh preflight verifies the release signature against <app>/env/cosign.pub
# and refuses to run without it. It is a public key, and the rehearsal verifies a
# real published release, so the production copy is the right one to use.
COSIGN_PUB="${MAJADU_REHEARSAL_COSIGN_PUB:-/srv/qouver/apps/majadu/env/cosign.pub}"
[ -f "$COSIGN_PUB" ] ||
  fail "release signature key $COSIGN_PUB is missing; set MAJADU_REHEARSAL_COSIGN_PUB"
install -m 644 "$COSIGN_PUB" "$SANDBOX/app/env/cosign.pub"
# The production snippets proxy to 127.0.0.1:8080, which on this host is the real
# Majadu container. A sandbox site that imported them verbatim would forward
# /majadu/* to production, so the port is rewritten here and cutover.sh preflight
# installs these copies instead of the repository's (MAJADU_CADDY_SRC).
CADDY_SRC="$SANDBOX/caddy-src"
mkdir -p "$CADDY_SRC"
for snippet in site-v1 site-v2 site-maintenance log-share; do
  install -m 644 "$REPO_ROOT/ops/caddy/$snippet.caddy" "$CADDY_SRC/$snippet.caddy"
done
sed -i "s|reverse_proxy 127.0.0.1:8080|reverse_proxy 127.0.0.1:$APP_PORT|" \
  "$CADDY_SRC/site-v1.caddy" "$CADDY_SRC/site-v2.caddy"
# Preflight installs the same files into $SANDBOX/app/caddy later. This copy is
# what the sandbox Caddy starts from before that step runs, so the site answers
# through Caddy during the v1 half of the rehearsal too.
install -m 644 "$CADDY_SRC/site-v1.caddy" "$SANDBOX/app/caddy/site-v1.caddy"
install -m 644 "$CADDY_SRC/log-share.caddy" "$SANDBOX/app/caddy/log-share.caddy"
ln -sfn "$SANDBOX/app/caddy/site-v1.caddy" "$SANDBOX/app/caddy/active.caddy"

# Sandbox Caddy: its own site, its own admin port, so a reload here cannot
# touch the production Caddyfile.
cat >"$SANDBOX/app/Caddyfile.rehearsal" <<EOF
{
	admin $CADDY_ADMIN
	auto_https off
}

# The host defines this snippet; its access log path is not writable as an
# unprivileged user, so the sandbox relies on Caddy's stderr instead. The
# share-code matcher is kept because cutover.sh preflight refuses a site that
# carries an active snippet without one.
(log_access) {
	output stderr
}

http://127.0.0.1:$SITE_PORT {
	import $SANDBOX/app/caddy/log-share.caddy
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
  "MAJADU_CADDY_SRC=$CADDY_SRC"
  "MAJADU_STAGING_DB=$STAGING_DB"
  "MAJADU_BM2_DB=$BM2_DB"
  # step_snapshot runs backup.sh, which dumps bm2 as well and refuses to run
  # without an owner DSN. The sandbox has no majadu-tools.env to fall back to.
  "MAJADU_BACKUP_DSN_BM2=$(sed -n 's/^MAJADU_OWNER_DSN=//p' "$ENV_DIR/v2.env" | tail -1)"
  # A bare `postgresql:///db` reaches the container's socket as the container
  # user (root), which is not a role here, so the source DSN has to name the
  # role explicitly.
  "MAJADU_CUTOVER_V1_DSN=postgresql://qouver@127.0.0.1:5432/$V1_DB"
  "MAJADU_OWNER_SUB=${MAJADU_OWNER_SUB:-rehearsal-owner}"
  # ownerseed refuses to create the owner without an email, so the rehearsal
  # needs one even though a real cutover on an existing owner does not.
  "MAJADU_OWNER_EMAIL=${MAJADU_OWNER_EMAIL:-rehearsal-owner@example.invalid}"
  # A failed rehearsal still pages someone, but the alert must not read as a
  # failed production cutover (cutover.sh defaults the unit to its own name).
  "MAJADU_ALERT_UNIT=rehearsal"
)

if [ "$DRY_RUN" -eq 1 ]; then
  printf 'rehearsal: dry run, nothing was executed. Would run:\n\n'
  printf '  psql %s -c "drop database if exists %s with (force)"\n' "$ADMIN_DSN" "$BM2_DB"
  printf '  psql %s -c "create database %s owner bm2_owner" && psql %s -f %s/ops/db/roles.sql -v db=%s\n' \
    "$ADMIN_DSN" "$BM2_DB" "$ADMIN_DSN" "$REPO_ROOT" "$BM2_DB"
  printf '  install -m 644 %s %s/%s.container && systemctl --user daemon-reload\n' \
    "$SANDBOX/$SERVICE.container" "$UNIT_DIR" "$SERVICE"
  printf '  caddy run --config %s --adapter caddyfile &\n' "$SANDBOX/app/Caddyfile.rehearsal"
  printf '  podman tag %s %s:v1-final && podman tag %s:v1-final %s:local\n' \
    "$V1_IMAGE" "$IMAGE" "$IMAGE" "$IMAGE"
  printf '  systemctl --user enable --now %s   # v1 must be running before the cutover preserves it\n' "$SERVICE"
  printf '  env %s \\\n' "${CUTOVER_ENV[*]}"
  printf '    %s/../scripts/cutover.sh --version v%s\n' "$REPO_ROOT/ops" "$VERSION"
  printf '  env %s \\\n' "${CUTOVER_ENV[*]}"
  printf '    %s/../scripts/rollback.sh\n' "$REPO_ROOT/ops"
  printf '\nSandbox assembled at %s. The restore step recreates %s from a dump\n' \
    "$SANDBOX" "$STAGING_DB"
  printf 'of %s, which is only read.\n' "$V1_DB"
  exit 0
fi

for tool in podman curl flock caddy; do
  command -v "$tool" >/dev/null 2>&1 || fail "$tool is required for run"
done
if [ "$USE_CONTAINER" -eq 1 ]; then
  podman container exists "$PG_CONTAINER" 2>/dev/null ||
    fail "host has no psql/createdb/dropdb and container '$PG_CONTAINER' does not exist"
  printf 'rehearsal: database tools via podman exec %s\n' "$PG_CONTAINER"
fi

[ "${MAJADU_REHEARSAL_CONFIRM:-}" = "yes" ] ||
  fail "set MAJADU_REHEARSAL_CONFIRM=yes after announcing the maintenance window"

# --- databases ------------------------------------------------------------
printf 'rehearsal: recreating %s and %s\n' "$BM2_DB" "$STAGING_DB"
psql_cmd "$ADMIN_DSN" -v ON_ERROR_STOP=1 -c "drop database if exists $BM2_DB with (force)" >/dev/null
# Owned by bm2_owner, not the admin role: roles.sql ends with
# `alter schema public owner to bm2_owner`, which the admin role cannot do on a
# database somebody else owns. Production bm2 is owned by bm2_owner too.
psql_cmd "$ADMIN_DSN" -v ON_ERROR_STOP=1 -c "create database $BM2_DB owner bm2_owner" >/dev/null
[ "$(psql_cmd "$ADMIN_DSN" -Atc \
  "select 1 from pg_database where datname = '$V1_DB'")" = "1" ] ||
  fail "$V1_DB does not exist; it is the read-only source of the rehearsal dump"
# v1 has to be running before the cutover starts, and it reads $STAGING_DB, so
# that database must exist from the first second. The cutover's own restore step
# replaces it later from a fresh dump; priming it here with a read-only copy of
# $V1_DB is what lets the v1 unit start without touching a production database.
printf 'rehearsal: priming %s with a read-only copy of %s\n' "$STAGING_DB" "$V1_DB"
psql_cmd "$ADMIN_DSN" -v ON_ERROR_STOP=1 \
  -c "drop database if exists $STAGING_DB with (force)" >/dev/null
psql_cmd "$ADMIN_DSN" -v ON_ERROR_STOP=1 \
  -c "create database $STAGING_DB" >/dev/null
pg_dump_cmd --format=custom --no-owner "$V1_DSN" >"$SANDBOX/app/backups/prime.dump"
# APP_DIR is passed explicitly: restore.sh defaults it to the production app
# directory, and its deploy lock and log path hang off that.
MAJADU_APP_DIR="$SANDBOX/app" \
  "$REPO_ROOT/ops/scripts/restore.sh" --file "$SANDBOX/app/backups/prime.dump" \
  --target "$STAGING_DB" \
  --dsn "postgresql://qouver@127.0.0.1:5432/$STAGING_DB" \
  --recreate --no-privileges >/dev/null
# Applied by the same role cutover.sh uses in step_prepare_bm2, so the rehearsal
# exercises the production path: bm2_owner on a database it owns. The DSN goes in
# as -d, not as a positional: a connection string in psql's dbname slot is read
# as a role name when options follow it.
psql_cmd -v ON_ERROR_STOP=1 -d "$(sed -n 's/^MAJADU_OWNER_DSN=//p' "$ENV_DIR/v2.env" | tail -1)" \
  -v db="$BM2_DB" <"$REPO_ROOT/ops/db/roles.sql" >/dev/null

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
# rehearsal container the preserve step has nothing to preserve. The v1 image is
# named, never guessed: :local is v2 after the first real cutover, and using it
# would prove a rollback from v2 to v2.
printf 'rehearsal: starting the v1 image the cutover will preserve\n'
podman image exists "$V1_IMAGE" ||
  fail "$V1_IMAGE is absent; the rollback half needs a real v1 image (set MAJADU_REHEARSAL_V1_IMAGE to point at one)"
podman tag "$V1_IMAGE" "$IMAGE:v1-final"
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
# `step_import` runs `majadu-import verify`, which compares v2's recomputed
# rating tallies against v1's stored `bm.rating_players`. Those disagree for 72
# of 141 players in the archive itself: v1's counter is not derivable from the
# games it kept, so the import cannot match it and verify exits 1. The
# 2026-11-15 production cutover hit exactly this, logged `"problems":9`, and
# continued with `--from state` once the mismatch was reviewed (its cutover.log
# is the evidence). The rehearsal reproduces that operator decision instead of
# failing on a condition production already carries.
#
# The count is pinned: a different number means something new broke and the run
# fails rather than inheriting the old waiver.
IMPORT_WAIVER_PROBLEMS=9
IMPORT_WAIVER=0

run_cutover() {
  local log="$SANDBOX/app/logs/cutover.log" before=0 step
  [ -f "$log" ] && before=$(wc -l <"$log")
  env "${CUTOVER_ENV[@]}" "$REPO_ROOT/ops/scripts/cutover.sh" \
    --version "v$VERSION" "$@" && return 0
  # Look only at what this invocation appended: the log is never truncated, so a
  # previous run's waiver line is still in it.
  step=$(sed -n 's/.*"step":"\([a-z-]*\)".*/\1/p' \
    "$SANDBOX/app/cutover/cutover.step" 2>/dev/null)
  [ "$step" = "import" ] || return 1
  tail -n +"$((before + 1))" "$log" 2>/dev/null |
    grep -q '"problems":'"$IMPORT_WAIVER_PROBLEMS"'}$' || return 1
  printf 'rehearsal: import verify reported %s known v1 tally mismatches; continuing from state\n' \
    "$IMPORT_WAIVER_PROBLEMS"
  IMPORT_WAIVER=1
  env "${CUTOVER_ENV[@]}" "$REPO_ROOT/ops/scripts/cutover.sh" \
    --version "v$VERSION" --from state
}

printf 'rehearsal: running the cutover\n'
started=$(date +%s)
cutover_ok=0
run_cutover && cutover_ok=1
finished=$(date +%s)

# Per-step seconds from the log cutover.sh writes next to its step marker. The
# log is appended to on every invocation, so a resumed run (the import waiver, or
# the --from proof) repeats steps that already ran; the JSON keys must stay
# unique and each step reports its slowest pass, so a resume cannot make the
# cutover look faster than one uninterrupted run.
steps_json=$(
  awk -F'\t' '
    $2 == "begin" { begin[$1] = $3; if (!($1 in seen)) { seen[$1] = 1; order[++n] = $1 } }
    $2 == "end" && ($1 in begin) {
      d = $3 - begin[$1]
      if (!($1 in worst) || d > worst[$1]) worst[$1] = d
    }
    END {
      for (i = 1; i <= n; i++) {
        name = order[i]
        if (!(name in worst)) continue
        printf "%s\"%s\": %d", (k++ ? ", " : ""), name, worst[name]
      }
    }
  ' "$SANDBOX/app/cutover/cutover.timings.tsv" 2>/dev/null || true
)
step_max() {
  awk -F'\t' -v want="$1" '
    $1 == want && $2 == "begin" { b = $3 }
    $1 == want && $2 == "end" && b > 0 { d = $3 - b; if (d > max) max = d; b = 0 }
    END { printf "%d\n", (max == "" ? 0 : max) }
  ' "$SANDBOX/app/cutover/cutover.timings.tsv" 2>/dev/null
}
total=$((finished - started))
restore=$(step_max restore-staging)
# The maintenance window is the first maintenance begin to the first readyz end
# after it: that is the stretch in which users saw the maintenance page.
window=$(awk -F'\t' '
  $1 == "maintenance" && $2 == "begin" && b == 0 { b = $3 }
  $1 == "readyz" && $2 == "end" && b > 0 { print $3 - b; exit }
' "$SANDBOX/app/cutover/cutover.timings.tsv" 2>/dev/null)
restore=${restore:-0}
window=${window:-0}

# The sandbox site must answer through Caddy, not just on the app port. The
# snippets handle `/majadu/*` and strip that prefix, so the bare `/version` is a
# 404 through the site; the check has to use the same path a client does.
site_ok=0
if body=$(curl -sS --max-time 5 "http://127.0.0.1:$SITE_PORT/majadu/version" 2>/dev/null) &&
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
# only automated way to prove resume without faking a failure mid-run. The tail
# contains `import`, so it hits the same verify mismatch and goes through
# run_cutover's waiver.
resume_proof=false
resume_seconds=0
if [ "$FROM_PROOF" -eq 1 ] && [ "$cutover_ok" -eq 1 ] && [ "$rollback_ok" -eq 1 ]; then
  printf 'rehearsal: proving --from restore-staging\n'
  resume_started=$(date +%s)
  if run_cutover --from restore-staging; then
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
  "import_waiver": $IMPORT_WAIVER,
  "import_waiver_problems": $IMPORT_WAIVER_PROBLEMS,
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
if [ "$IMPORT_WAIVER" -eq 1 ]; then
  printf '%-22s %8s\n' "import verify" "waived ($IMPORT_WAIVER_PROBLEMS known v1 tally mismatches)"
fi
printf '\nrehearsal: %s; timings written to %s\n' "$status" "${TIMINGS#$REPO_ROOT/}"
[ "$status" = "passed" ] || exit 1
