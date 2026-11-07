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

# The webhook runs the installed copy, so refresh it from the checkout it just
# synced. Bash keeps reading the old inode, which is why the replace is atomic:
# this run keeps its own code and the next one starts from the branch.
SELF_INSTALL="$APP_DIR/scripts/deploy-vps-rc.sh"
install -m 755 "$MONO_DIR/ops/scripts/deploy-vps-rc.sh" "$SELF_INSTALL.new"
mv -f "$SELF_INSTALL.new" "$SELF_INSTALL"

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
APP_DSN=$(sed -n 's/^MAJADU_PG_DSN=//p' "$ENV_FILE" | tail -1)
[ -n "$OWNER_DSN" ] || fail "MAJADU_OWNER_DSN is missing from $ENV_FILE"
[ -n "$APP_DSN" ] || fail "MAJADU_PG_DSN is missing from $ENV_FILE"
# The role names are shared with the future bm2, so the database name is the
# only thing that keeps this instance away from production data. Refuse a file
# that points somewhere else instead of deploying it.
OWNER_DB=$(printf '%s' "$OWNER_DSN" | sed 's/.*\///' | cut -d'?' -f1)
APP_DB=$(printf '%s' "$APP_DSN" | sed 's/.*\///' | cut -d'?' -f1)
[ "$OWNER_DB" = "bm2_rc" ] || fail "MAJADU_OWNER_DSN points at '$OWNER_DB', not bm2_rc"
[ "$APP_DB" = "bm2_rc" ] || fail "MAJADU_PG_DSN points at '$APP_DB', not bm2_rc"

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
# The unit bind-mounts this path; podman refuses to start when it is missing.
mkdir -p "$APP_DIR/logs/main"
mkdir -p "$(dirname "$UNIT_DEST")"
if ! cmp -s "$UNIT_SRC" "$UNIT_DEST"; then
  install -m 644 "$UNIT_SRC" "$UNIT_DEST"
  log "unit majadu-rc-api.container updated from the repository"
fi
# Always reload: the quadlet generator only creates the .service when it runs, so
# a unit file that was already in place (bootstrap installs it) never becomes a
# startable unit otherwise.
service daemon-reload >/dev/null 2>&1 || true

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

# ---------------------------------------------------------------------------
# FE. The token is optional: without it the API still deploys and the web build
# stays with whatever pipeline the project has. With it the same push updates
# both, and no GitHub App or repository collaborator is involved.
#
# The build runs on the VPS, so the CLI's project root directory is the same
# apps/web the Git pipeline would use; `vercel build` reads the project settings
# (install, build, output) that were applied through the API.
# ---------------------------------------------------------------------------
STEP="web"
WEB_URL=""
VERCEL_TOKEN_FILE="$APP_DIR/env/vercel-token"
if [ ! -f "$VERCEL_TOKEN_FILE" ]; then
  log "no vercel-token in $APP_DIR/env; skipping the web deploy"
else
  WEB_MODE=$(file_mode "$VERCEL_TOKEN_FILE")
  case "$WEB_MODE" in
    600|400) ;;
    *) fail "$VERCEL_TOKEN_FILE must be mode 600 (found $WEB_MODE)" ;;
  esac
  VERCEL_BIN="${MAJADU_RC_VERCEL_BIN:-$HOME/.local/share/pnpm/bin/vercel}"
  [ -x "$VERCEL_BIN" ] || fail "vercel CLI not found at $VERCEL_BIN"
  TARGET_SCOPE="${MAJADU_RC_VERCEL_SCOPE:-qouver}"
  TARGET_PROJECT="${MAJADU_RC_VERCEL_PROJECT:-majadu-rc}"
  TOKEN=$(cat "$VERCEL_TOKEN_FILE")
  # fnm keeps node outside the login PATH this script inherits, and pnpm lives
  # in a third place again; `vercel build` runs the project's install command.
  export PATH="$HOME/.local/share/fnm/aliases/default/bin:$HOME/.local/share/pnpm/bin:$PATH"

  # Run from the repository root: the project's root directory is apps/web, and
  # the CLI resolves it relative to the working directory. Invoking it from
  # apps/web makes it look for apps/web/apps/web.
  cd "$MONO_DIR"
  "$VERCEL_BIN" link --yes --scope "$TARGET_SCOPE" --project "$TARGET_PROJECT" \
    --token "$TOKEN" >>"$LOG" 2>&1 || fail "vercel link failed"
  "$VERCEL_BIN" pull --yes --environment=production --token "$TOKEN" >>"$LOG" 2>&1 ||
    fail "vercel pull failed"
  # `vercel build` reuses whatever output directory is already there, including
  # builds.json from a failed attempt, and a deploy then refuses the stale
  # record. Start from nothing so the build that is deployed is this one.
  rm -rf "$MONO_DIR/.vercel/output"
  "$VERCEL_BIN" build --prod --token "$TOKEN" >>"$LOG" 2>&1 || fail "vercel build failed"
  DEPLOY_JSON=$("$VERCEL_BIN" deploy --prebuilt --prod --yes --json --token "$TOKEN" \
    2>>"$LOG" || true)
  WEB_URL=$(printf '%s' "$DEPLOY_JSON" | sed -n 's/.*"url":[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
  [ -n "$WEB_URL" ] || fail "vercel deploy returned no url"
  # The CLI reports a bare host on some versions and a full URL on others.
  case "$WEB_URL" in
    *://*) ;;
    *) WEB_URL="https://$WEB_URL" ;;
  esac
  log "web deployed: $WEB_URL"
  cd "$MONO_DIR"
fi

printf '{"version":"%s","commit":"%s","schema":"%s","branch":"%s","web":"%s","at":"%s"}\n' \
  "$VERSION" "$COMMIT" "$SCHEMA" "$BRANCH" "$WEB_URL" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
  >"$STATE_DIR/last-release.json"

# Retention: only :local and :prev stay tagged; everything the rotation left
# untagged goes away. No commit-SHA tags are created anywhere.
STEP="prune"
podman image prune -f >>"$LOG" 2>&1 || true

log "deployed $COMMIT (v$VERSION, schema $SCHEMA)"