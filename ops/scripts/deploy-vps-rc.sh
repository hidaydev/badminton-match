#!/usr/bin/env bash
# Deploy the RC API instance after a push to the RC branch.
#
# Trigger: GitHub webhook -> webhook.service -> this script, with the repository
# name and the git ref as arguments. Live copy:
# /srv/qouver/apps/majadu-rc/scripts/deploy-vps-rc.sh; this file in the
# repository is the source of truth.
#
# Deliberately different from deploy-vps.sh: the RC builds on the VPS from the
# checkout, because it deploys on every push while the release path is gated on
# a signed tag plus VERSION. Production keeps deploying by digest.
#
# The guard is fail-closed and literal. A push to any other ref, including an
# empty ref, leaves the instance alone.
#
# Overridable for a rehearsal host: MAJADU_RC_APP_DIR, MAJADU_RC_SERVICE,
# MAJADU_RC_IMAGE, MAJADU_RC_HEALTH_URL, MAJADU_RC_NETWORK, MAJADU_RC_BRANCH,
# MAJADU_RC_SKIP_GIT_SYNC, MAJADU_SERVICE_CMD.
set -euo pipefail

REPO_NAME="${1:-badminton-match}"
REF="${2:-}"

APP_DIR="${MAJADU_RC_APP_DIR:-/srv/qouver/apps/majadu-rc}"
SERVICE="${MAJADU_RC_SERVICE:-majadu-rc-api}"
LOCAL_IMAGE="${MAJADU_RC_IMAGE:-localhost/majadu-rc-api}"
GITHUB_REPO="${MAJADU_GITHUB_REPO:-hidaydev/badminton-match}"
BRANCH="${MAJADU_RC_BRANCH:-release/2.0.0-rc.1}"
HEALTH_URL="${MAJADU_RC_HEALTH_URL:-http://127.0.0.1:8081}"
NETWORK="${MAJADU_RC_NETWORK:-qouver}"
MONO_DIR="$APP_DIR/repo"
ENV_FILE="$APP_DIR/env/majadu-rc.env"
STATE_DIR="$APP_DIR/deploy"
LOG="$APP_DIR/logs/deploy.log"
LOCK_FILE="$APP_DIR/.deploy.lock"

STEP="start"
SCHEMA=""

mkdir -p "$APP_DIR/logs" "$STATE_DIR"

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOG"
}

fail() {
  log "ERROR: $1 (step: $STEP)"
  printf '{"step":"%s","message":"%s","at":"%s"}\n' \
    "$STEP" "$1" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    >"$STATE_DIR/last-release.json"
  exit 1
}

trap 'fail "command failed at line $LINENO"' ERR

file_mode() {
  stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null || echo "?"
}

service() {
  if [ -n "${MAJADU_SERVICE_CMD:-}" ]; then
    "$MAJADU_SERVICE_CMD" "$@"
  else
    systemctl --user "$@"
  fi
}

run_tool() {
  local entry="$1" dsn="$2"
  shift 2
  podman run --rm --network "$NETWORK" -e MAJADU_PG_DSN="$dsn" \
    --entrypoint "$entry" "$LOCAL_IMAGE:local" "$@"
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

# Fail closed: anything that is not a push to the RC branch must not deploy.
if [ "$REF" != "refs/heads/${MAJADU_RC_BRANCH:-release/2.0.0-rc.1}" ]; then
  echo "deploy ignored: ref '${REF:-<empty>}' is not refs/heads/${MAJADU_RC_BRANCH:-release/2.0.0-rc.1}"
  exit 0
fi

if [ "$REPO_NAME" != "badminton-match" ]; then
  echo "deploy ignored: repository '$REPO_NAME' is not badminton-match"
  exit 0
fi

log "deploy trigger for $REPO_NAME $REF"

exec 9>"$LOCK_FILE"
if ! flock -w 900 9; then
  log "another deploy still holds the lock after 900s; giving up"
  exit 1
fi

# ---------------------------------------------------------------------------
# Checkout: fetch + reset survives a force-push.
# ---------------------------------------------------------------------------
if [ "${MAJADU_RC_SKIP_GIT_SYNC:-0}" != "1" ]; then
  STEP="git-sync"
  if [ -d "$MONO_DIR/.git" ]; then
    cd "$MONO_DIR"
    git fetch origin "$BRANCH" >>"$LOG" 2>&1
    git reset --hard "origin/$BRANCH" >>"$LOG" 2>&1
  else
    git clone "https://github.com/$GITHUB_REPO.git" "$MONO_DIR" >>"$LOG" 2>&1
    cd "$MONO_DIR"
    git checkout -B "$BRANCH" "origin/$BRANCH" >>"$LOG" 2>&1
  fi
fi

cd "$MONO_DIR"
COMMIT=$(git rev-parse HEAD)
VERSION=$(tr -d '[:space:]' <VERSION)
[ -n "$VERSION" ] || fail "VERSION is empty"

# ---------------------------------------------------------------------------
# The env file is the only place the DSN lives. A missing or world-readable file
# is a failed deploy, not a reason to guess.
# ---------------------------------------------------------------------------
STEP="env-check"
[ -f "$ENV_FILE" ] || fail "env file $ENV_FILE is missing"
MODE=$(file_mode "$ENV_FILE")
case "$MODE" in
  600|400) ;;
  *) fail "$ENV_FILE must be mode 600 (found $MODE)" ;;
esac
OWNER_DSN=$(sed -n 's/^MAJADU_OWNER_DSN=//p' "$ENV_FILE" | tail -1)
[ -n "$OWNER_DSN" ] || fail "MAJADU_OWNER_DSN is missing from $ENV_FILE"

# ---------------------------------------------------------------------------
# Build. The previous :local becomes :prev first, so a failed build still
# leaves a startable pair; podman only moves :local when the build succeeds.
# ---------------------------------------------------------------------------
STEP="build"
if podman image exists "$LOCAL_IMAGE:local"; then
  podman tag "$LOCAL_IMAGE:local" "$LOCAL_IMAGE:prev"
fi
podman build -f apps/api/Dockerfile \
  --build-arg APP_VERSION="$VERSION" \
  --build-arg APP_COMMIT="$COMMIT" \
  -t "$LOCAL_IMAGE:local" . >>"$LOG" 2>&1 ||
  fail "podman build failed; :local was not replaced"
log "built $LOCAL_IMAGE:local at $COMMIT"

# ---------------------------------------------------------------------------
# Schema first, service second. Migrations are one transaction under an
# advisory lock; verify proves the ledger matches the committed files.
# ---------------------------------------------------------------------------
STEP="migrate"
run_tool /usr/local/bin/dbtools "$OWNER_DSN" \
  migrate --dir /app/db/migrations >>"$LOG" 2>&1 ||
  fail "dbtools migrate failed; the running release was left alone"

STEP="verify-schema"
run_tool /usr/local/bin/dbtools "$OWNER_DSN" \
  verify --dir /app/db/migrations >>"$LOG" 2>&1 ||
  fail "dbtools verify failed; the database is not at the committed schema"
SCHEMA=$(basename "$(ls "$MONO_DIR"/db/migrations/*.sql | tail -1)" .sql)
log "schema verified at $SCHEMA"

# Seeds are recorded by checksum and overwrite platform defaults, so they run
# once. bootstrap-rc.sh writes the marker after the first seed.
STEP="seed"
if [ ! -f "$STATE_DIR/seeded" ]; then
  run_tool /usr/local/bin/dbtools "$OWNER_DSN" \
    seed --dir /app/db/seeds >>"$LOG" 2>&1 ||
    fail "dbtools seed failed"
  date -u '+%Y-%m-%dT%H:%M:%SZ' >"$STATE_DIR/seeded"
  log "seeded the platform defaults"
fi

# ---------------------------------------------------------------------------
# Unit comes from the repository, not from whatever was left on the VPS.
# ---------------------------------------------------------------------------
STEP="sync-unit"
UNIT_SRC="$MONO_DIR/ops/systemd/majadu-rc-api.container"
UNIT_DEST="$HOME/.config/containers/systemd/majadu-rc-api.container"
mkdir -p "$(dirname "$UNIT_DEST")"
if ! cmp -s "$UNIT_SRC" "$UNIT_DEST"; then
  install -m 644 "$UNIT_SRC" "$UNIT_DEST"
  service daemon-reload >/dev/null 2>&1 || true
  log "unit majadu-rc-api.container updated from the repository"
fi

STEP="restart"
service restart "$SERVICE" >>"$LOG" 2>&1

STEP="readiness"
if ! wait_ready; then
  log "readiness gate failed; rolling back to :prev"
  if podman image exists "$LOCAL_IMAGE:prev"; then
    podman tag "$LOCAL_IMAGE:prev" "$LOCAL_IMAGE:local"
    service restart "$SERVICE" >>"$LOG" 2>&1 || true
    if wait_ready; then
      log "rolled back: :prev answers /readyz"
    else
      log "ERROR: rollback did not become ready either"
    fi
  else
    log "ERROR: no :prev image to roll back to"
  fi
  fail "readiness gate failed for $COMMIT"
fi

STEP="smoke"
bash "$MONO_DIR/ops/scripts/smoke.sh" "$HEALTH_URL" "$VERSION" >>"$LOG" 2>&1 ||
  fail "smoke test failed for $COMMIT; see $LOG"

STEP="verify-build"
ANSWERED=$(curl -fsS --max-time 5 "$HEALTH_URL/version" 2>/dev/null || true)
case "$ANSWERED" in
  *"\"commit\":\"$COMMIT\""*) ;;
  *) fail "/version does not report commit $COMMIT: $ANSWERED" ;;
esac

printf '{"version":"%s","commit":"%s","schema":"%s","branch":"%s","at":"%s"}\n' \
  "$VERSION" "$COMMIT" "$SCHEMA" "$BRANCH" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
  >"$STATE_DIR/last-release.json"

# Retention: only :local and :prev stay tagged; everything the rotation left
# untagged goes away. No commit-SHA tags are created anywhere.
STEP="prune"
podman image prune -f >>"$LOG" 2>&1 || true

log "deployed $COMMIT (v$VERSION, schema $SCHEMA)"