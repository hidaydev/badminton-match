#!/usr/bin/env bash
# Deploy the released image after a push to main.
#
# Trigger: GitHub webhook -> webhook.service -> this script, with the repository
# name and the git ref as arguments. Live copy: /srv/qouver/apps/majadu/scripts/
# deploy-vps.sh; this file in the repository is the source of truth.
#
# The image is built once by the release workflow and pulled here by digest, so
# what runs in production is exactly what was tagged. This script never runs the
# cutover: until the operator has moved production to `bm2`, it only syncs the
# checkout and leaves v1 alone (the Dockerfile in this repository is already the
# v2 build, so deploying before the cutover would point v2 at the v1 schema).
#
# Overridable for rehearsal (T-063): MAJADU_APP_DIR, MAJADU_SERVICE,
# MAJADU_IMAGE, MAJADU_REGISTRY_IMAGE, MAJADU_SERVICE_CMD, MAJADU_SKIP_GIT_SYNC,
# MAJADU_HEALTH_URL.
set -euo pipefail

REPO_NAME="${1:-badminton-match}"
REF="${2:-}"

APP_DIR="${MAJADU_APP_DIR:-/srv/qouver/apps/majadu}"
SERVICE="${MAJADU_SERVICE:-majadu-api}"
LOCAL_IMAGE="${MAJADU_IMAGE:-localhost/majadu-api}"
REGISTRY_IMAGE="${MAJADU_REGISTRY_IMAGE:-ghcr.io/hidaydev/badminton-match}"
GITHUB_REPO="${MAJADU_GITHUB_REPO:-hidaydev/badminton-match}"
HEALTH_URL="${MAJADU_HEALTH_URL:-http://127.0.0.1:8080}"
MONO_DIR="$APP_DIR/monorepo"
ENV_FILE="$APP_DIR/env/majadu-prod.env"
STATE_DIR="$APP_DIR/deploy"
LOG="$APP_DIR/logs/deploy.log"
LOCK_FILE="$APP_DIR/.deploy.lock"

STEP="start"
mkdir -p "$APP_DIR/logs" "$STATE_DIR"

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOG"
}

alert() {
  if systemctl --user list-unit-files 'majadu-alert@.service' >/dev/null 2>&1; then
    systemctl --user start majadu-alert@deploy.service >/dev/null 2>&1 || true
  fi
}

file_mode() {
  stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null || echo "?"
}

require_private_file() {
  local path="$1" mode
  [ -f "$path" ] || return 0
  mode=$(file_mode "$path")
  case "$mode" in
    600|400) ;;
    *) fail "$path must be mode 600 (found $mode)" ;;
  esac
}

fail() {
  local message="$1"
  log "ERROR: $message (step: $STEP)"
  printf '{"step":"%s","message":"%s","at":"%s"}\n' \
    "$STEP" "$message" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    >"$STATE_DIR/last-release.json"
  alert
  exit 1
}

trap 'fail "command failed at line $LINENO"' ERR

service() {
  if [ -n "${MAJADU_SERVICE_CMD:-}" ]; then
    "$MAJADU_SERVICE_CMD" "$@"
  else
    systemctl --user "$@"
  fi
}

# Fail closed: anything that is not a push to main must not deploy. An empty ref
# takes this branch too, which is why the literal comparison is used.
if [ "$REF" != "refs/heads/main" ]; then
  echo "deploy ignored: ref '${REF:-<empty>}' is not refs/heads/main"
  exit 0
fi

if [ "$REPO_NAME" != "badminton-match" ]; then
  echo "deploy ignored: repository '$REPO_NAME' is not badminton-match"
  exit 0
fi

log "deploy trigger for $REPO_NAME"

# ---------------------------------------------------------------------------
# Checkout: fetch + reset survives a force-push; the old revision is kept only
# long enough to know what changed.
# ---------------------------------------------------------------------------
if [ "${MAJADU_SKIP_GIT_SYNC:-0}" != "1" ]; then
  STEP="git-sync"
  if [ -d "$MONO_DIR/.git" ]; then
    cd "$MONO_DIR"
    git fetch origin main >>"$LOG" 2>&1
    git reset --hard origin/main >>"$LOG" 2>&1
    NEW_REV=$(git rev-parse HEAD)
  else
    git clone "https://github.com/$GITHUB_REPO.git" "$MONO_DIR" >>"$LOG" 2>&1
    cd "$MONO_DIR"
    git checkout -B main origin/main >>"$LOG" 2>&1
    NEW_REV=$(git rev-parse HEAD)
  fi
else
  cd "$MONO_DIR"
  NEW_REV=$(git rev-parse HEAD)
fi

# ---------------------------------------------------------------------------
# Self re-exec: a push that changes this script must deploy with the new logic
# on that same push. The lock is taken after the new copy is in place.
# ---------------------------------------------------------------------------
SELF="$APP_DIR/scripts/deploy-vps.sh"
REPO_SCRIPT="$MONO_DIR/ops/scripts/deploy-vps.sh"
if [ "${MAJADU_SKIP_GIT_SYNC:-0}" != "1" ] && [ -f "$REPO_SCRIPT" ] && ! cmp -s "$REPO_SCRIPT" "$SELF"; then
  TMP="$SELF.new.$$"
  if cp -f "$REPO_SCRIPT" "$TMP" && bash -n "$TMP" && chmod 755 "$TMP"; then
    mv -f "$TMP" "$SELF"
    log "deploy script updated from the repository; re-executing"
    exec "$SELF" "$REPO_NAME" "$REF"
  fi
  rm -f "$TMP"
  log "WARNING: repository deploy script did not pass bash -n; keeping the current one"
fi

# ---------------------------------------------------------------------------
# Concurrency: wait up to 15 minutes for the running deploy, never silently drop
# a release.
# ---------------------------------------------------------------------------
exec 9>"$LOCK_FILE"
if ! flock -w 900 9; then
  log "another deploy still holds the lock after 900s; giving up"
  exit 1
fi

# ---------------------------------------------------------------------------
# Cutover gate: production keeps the v1 database until the operator runs
# cutover.sh. The prod env file is the switch, not a marker file: while its DSN
# still names `bm`, this repository's image (already v2) must not run there.
# ---------------------------------------------------------------------------
STEP="cutover-gate"
PROD_DSN=$(sed -n 's/^MAJADU_PG_DSN=//p' "$ENV_FILE" 2>/dev/null | tail -1)
case "$PROD_DSN" in
  */bm2|*/bm2\?*|*/bm2\"*) ;;
  *)
    log "production does not point at bm2 yet: cutover has not happened, nothing to deploy"
    exit 0
    ;;
esac

VERSION=$(tr -d '[:space:]' <"$MONO_DIR/VERSION")
[ -n "$VERSION" ] || fail "VERSION is empty"

# The decision is the version, not a path filter: a commit that only bumps
# VERSION is a release and must deploy, while a documentation push that leaves
# VERSION alone must not restart the service.
DEPLOYED=""
[ -f "$STATE_DIR/deployed-version" ] && DEPLOYED=$(cat "$STATE_DIR/deployed-version")
if [ "$DEPLOYED" = "$VERSION" ]; then
  log "version $VERSION is already live; nothing to do"
  exit 0
fi

# ---------------------------------------------------------------------------
# Resolve the digest published with the release. The release workflow records
# it in the release notes, so the tag alone never decides what runs.
# ---------------------------------------------------------------------------
STEP="resolve-digest"
TOKEN_FILE="$APP_DIR/env/ghcr-token"
require_private_file "$ENV_FILE"
require_private_file "$TOKEN_FILE"
AUTH=()
if [ -f "$TOKEN_FILE" ]; then
  AUTH=(-H "Authorization: Bearer $(cat "$TOKEN_FILE")")
elif [ -n "${GITHUB_TOKEN:-}" ]; then
  AUTH=(-H "Authorization: Bearer $GITHUB_TOKEN")
fi
RELEASE=$(curl -fsS --max-time 20 -H "Accept: application/vnd.github+json" \
  "${AUTH[@]}" "https://api.github.com/repos/$GITHUB_REPO/releases/tags/v$VERSION" 2>/dev/null || true)
DIGEST=$(printf '%s' "$RELEASE" | grep -oE 'sha256:[0-9a-f]{64}' | head -1)
if [ -z "$DIGEST" ]; then
  fail "release v$VERSION has no published image digest"
fi
log "release v$VERSION resolves to $DIGEST"

STEP="registry-login"
if [ -f "$TOKEN_FILE" ]; then
  podman login ghcr.io -u "${MAJADU_GHCR_USER:-hidaydev}" --password-stdin \
    <"$TOKEN_FILE" >>"$LOG" 2>&1 || fail "podman login ghcr.io failed"
else
  log "no GHCR token file; using the existing podman credentials"
fi

STEP="pull"
PULLED=0
if podman pull "$REGISTRY_IMAGE@$DIGEST" >>"$LOG" 2>&1; then
  PULLED=1
  log "pulled $REGISTRY_IMAGE@$DIGEST"
else
  log "registry unreachable; keeping :prev instead of the release image"
fi

STEP="rotate"
if [ "$PULLED" -eq 1 ]; then
  PULLED_ID=$(podman image inspect --format '{{.Id}}' "$REGISTRY_IMAGE@$DIGEST")
  CURRENT_ID=""
  if podman image exists "$LOCAL_IMAGE:local"; then
    CURRENT_ID=$(podman image inspect --format '{{.Id}}' "$LOCAL_IMAGE:local")
  fi
  # A redeploy of the same digest must not rotate :prev onto the image it is
  # meant to replace.
  if [ "$PULLED_ID" != "$CURRENT_ID" ] && [ -n "$CURRENT_ID" ]; then
    podman tag "$LOCAL_IMAGE:local" "$LOCAL_IMAGE:prev"
  fi
  podman tag "$REGISTRY_IMAGE@$DIGEST" "$LOCAL_IMAGE:local"
elif ! podman image exists "$LOCAL_IMAGE:prev"; then
  fail "registry unreachable and no :prev image to fall back to"
else
  podman tag "$LOCAL_IMAGE:prev" "$LOCAL_IMAGE:local"
fi

# ---------------------------------------------------------------------------
# Units come from the repository, not from whatever was left on the VPS.
# ---------------------------------------------------------------------------
STEP="sync-units"
# Quadlet reads .container files; the alert template is a plain user service.
for kind in container service; do
  if [ "$kind" = "container" ]; then
    UNIT_DEST="$HOME/.config/containers/systemd"
  else
    UNIT_DEST="$HOME/.config/systemd/user"
  fi
  mkdir -p "$UNIT_DEST"
  for SRC in "$MONO_DIR"/ops/systemd/*."$kind"; do
    [ -f "$SRC" ] || continue
    NAME=$(basename "$SRC")
    if ! cmp -s "$SRC" "$UNIT_DEST/$NAME"; then
      [ -f "$UNIT_DEST/$NAME" ] && cp -f "$UNIT_DEST/$NAME" "$UNIT_DEST/$NAME.bak"
      install -m 644 "$SRC" "$UNIT_DEST/$NAME"
      log "unit $NAME updated from the repository"
    fi
  done
done
service daemon-reload >/dev/null 2>&1 || true

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
  fail "readiness gate failed for v$VERSION"
fi

STEP="verify-image"
CONTAINER_IMAGE=$(podman inspect --format '{{.Image}}' "$SERVICE" 2>/dev/null || true)
LOCAL_ID=$(podman image inspect --format '{{.Id}}' "$LOCAL_IMAGE:local")
if [ -n "$CONTAINER_IMAGE" ] && [ "$CONTAINER_IMAGE" != "$LOCAL_ID" ]; then
  fail "container is not running the :local image"
fi

printf '%s\n' "$VERSION" >"$STATE_DIR/deployed-version"
printf '{"version":"%s","commit":"%s","digest":"%s","at":"%s"}\n' \
  "$VERSION" "$NEW_REV" "$DIGEST" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
  >"$STATE_DIR/last-release.json"

# Retention: :local and :prev stay tagged, :v1-final is never touched, and
# everything the rotation left untagged goes away.
STEP="prune"
podman image prune -f >>"$LOG" 2>&1 || true

log "deployed v$VERSION ($DIGEST)"
