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
# MAJADU_HEALTH_URL, MAJADU_CUTOVER_NETWORK.
#
# Before restarting, the migrations shipped in the pulled image are applied and
# verified (`dbtools migrate` + `dbtools verify`, both against MAJADU_OWNER_DSN
# from $APP_DIR/env/majadu-tools.env; the API unit never loads that file).
# A failure there leaves the running release and the tags untouched. Migrations
# must therefore stay expand/contract: `:prev` has to keep serving on the new
# schema, because that is what the readiness rollback starts.
#
# The schema a release expects is the last migration file in the image, and it
# is recorded in last-release.json next to the image digest. A rollback or an
# audit reads it from there instead of walking db/migrations at the old commit.
#
# After readiness, `scripts/smoke.sh` asserts that `/version` reports the release
# that was just pulled, not just that a process is up.
#
# The ERR trap is installed at the top level, so `set -E` is what carries it into
# functions and command substitutions. Without it a failure inside `service` or
# `wait_ready` exits through `set -e` with no ERROR line, no alert and no
# last-attempt.json.
set -Eeuo pipefail

# The log holds request paths and share codes are bearer credentials, so every
# file these scripts create is private from the first byte instead of waiting for
# the hourly rotation to chmod it.
umask 077

REPO_NAME="${1:-badminton-match}"
REF="${2:-}"

APP_DIR="${MAJADU_APP_DIR:-/srv/qouver/apps/majadu}"
SERVICE="${MAJADU_SERVICE:-majadu-api}"
LOCAL_IMAGE="${MAJADU_IMAGE:-localhost/majadu-api}"
REGISTRY_IMAGE="${MAJADU_REGISTRY_IMAGE:-ghcr.io/hidaydev/badminton-match}"
GITHUB_REPO="${MAJADU_GITHUB_REPO:-hidaydev/badminton-match}"
HEALTH_URL="${MAJADU_HEALTH_URL:-http://127.0.0.1:8080}"
# The database lives on the `qouver` podman network, so a one-shot tool
# container needs the same network the API unit declares.
NETWORK="${MAJADU_CUTOVER_NETWORK:-qouver}"
MONO_DIR="$APP_DIR/monorepo"
ENV_FILE="$APP_DIR/env/majadu-prod.env"
TOOLS_ENV="$APP_DIR/env/majadu-tools.env"
STATE_DIR="$APP_DIR/deploy"
LOG="$APP_DIR/logs/deploy.log"
LOCK_FILE="$APP_DIR/.deploy.lock"

STEP="start"
SCHEMA=""
install -d -m 700 "$APP_DIR/logs" "$STATE_DIR"
: >>"$LOG"
chmod 600 "$LOG" 2>/dev/null || true

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

# One record, one rename. A crash, a full disk or a SIGKILL between two `>`
# redirections used to leave half-written JSON and a version with no digest;
# the temp file is fsynced and renamed in the same directory, so a reader sees
# either the previous record or the new one.
atomic_write() {
  local dest="$1" tmp="$1.tmp.$$"
  cat >"$tmp"
  sync
  mv -f "$tmp" "$dest"
}

json_field() {
  # A missing state file is the first deploy, not a failure. GNU sed exits 2 on
  # it, and `set -o pipefail` turned that into a failed `fail()` before its
  # message was written.
  [ -f "$1" ] || return 0
  sed -n "s/.*\"$2\":\"\([^\"]*\)\".*/\1/p" "$1" 2>/dev/null | head -1
}

# A failed attempt must not erase the record of what is still serving. The
# failure goes to last-attempt.json with the running release's version, schema
# and digest copied in; last-release.json is written only by a successful
# deploy and is the input a rollback or an audit reads.
fail() {
  local message="$1" run_version run_schema run_digest
  log "ERROR: $message (step: $STEP)"
  run_version=$(json_field "$STATE_DIR/last-release.json" version)
  run_schema=$(json_field "$STATE_DIR/last-release.json" schema)
  run_digest=$(json_field "$STATE_DIR/last-release.json" digest)
  : "${run_version:=${VERSION:-unknown}}"
  : "${run_schema:=${SCHEMA:-unknown}}"
  : "${run_digest:=${DIGEST:-unknown}}"
  printf '{"step":"%s","message":"%s","version":"%s","schema":"%s","digest":"%s","at":"%s"}\n' \
    "$STEP" "$message" "$run_version" "$run_schema" "$run_digest" \
    "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" |
    atomic_write "$STATE_DIR/last-attempt.json"
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

# One-shot tool from the image that was just pulled, not from :local: :local may
# still be the previous release until the rotation step runs.
run_tool() {
  local entry="$1" dsn="$2"
  shift 2
  podman run --rm --network "$NETWORK" -e MAJADU_PG_DSN="$dsn" \
    --entrypoint "$entry" "$REGISTRY_IMAGE@$DIGEST" "$@"
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
if ! flock -w 1200 9; then
  log "another deploy still holds the lock after 900s; giving up"
  exit 1
fi

# ---------------------------------------------------------------------------
# Cutover gate: production keeps the v1 database until the operator runs
# cutover.sh. The prod env file is the switch, not a marker file: while its DSN
# still names `bm`, this repository's image (already v2) must not run there.
# ---------------------------------------------------------------------------
STEP="cutover-gate"
# A missing env file is not "the cutover has not happened": it means the deploy
# cannot tell which database it is about to serve, so it fails instead of
# reporting success.
[ -f "$ENV_FILE" ] || fail "prod env file $ENV_FILE is missing"
PROD_DSN=$(sed -n 's/^MAJADU_PG_DSN=//p' "$ENV_FILE" | tail -1)
case "$PROD_DSN" in
  */bm2|*/bm2\?*|*/bm2\"*) ;;
  *)
    log "production does not point at bm2 yet: cutover has not happened, nothing to deploy"
    exit 0
    ;;
esac

# The cutover gate exited 0 on a pre-cutover host, so everything below only
# applies once production points at bm2. The tool file holds the owner DSN the
# migrate step needs; check it before the digest and the image pull so a host
# that never created it fails fast instead of after pulling a release it cannot
# migrate.
[ -f "$TOOLS_ENV" ] || fail "tool env file $TOOLS_ENV is missing; copy ops/env/prod-tools.env.example"

# This file is the API unit's EnvironmentFile. A leftover owner, ETL or audit
# DSN from the single-file layout would be handed to the public process, so the
# deploy stops and names the line instead of starting a container with it.
# systemd skips leading whitespace, allows whitespace around `=`, and accepts an
# `export` prefix, so the match has to see those forms; comments do not match.
STEP="env-split"
for key in MAJADU_OWNER_DSN MAJADU_ETL_DSN MAJADU_ETL_SOURCE_DSN MAJADU_BACKUP_DSN_BM2 \
  MAJADU_CUTOVER_RESTORE_DSN MAJADU_AUDIT_DSN; do
  if hit=$(grep -Ein "^[[:space:]]*(export[[:space:]]+)?${key}[[:space:]]*=" "$ENV_FILE"); then
    fail "$ENV_FILE:${hit%%:*} must not contain $key; move it to $TOOLS_ENV"
  fi
done

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
# The owner and ETL DSNs are for the deploy and cutover tools, not for the API
# unit. They live next to the API env in a second file that the unit never
# loads, and that file too must stay private.
require_private_file "$TOOLS_ENV"
require_private_file "$TOKEN_FILE"
AUTH=()
if [ -f "$TOKEN_FILE" ]; then
  AUTH=(-H "Authorization: Bearer $(cat "$TOKEN_FILE")")
elif [ -n "${GITHUB_TOKEN:-}" ]; then
  AUTH=(-H "Authorization: Bearer $GITHUB_TOKEN")
fi
RELEASE=$(curl -fsS --max-time 20 -H "Accept: application/vnd.github+json" \
  "${AUTH[@]}" "https://api.github.com/repos/$GITHUB_REPO/releases/tags/v$VERSION" 2>/dev/null || true)
# The release body starts with the tag message, which is human-writable, so a
# digest-shaped string anywhere in it is not a binding. `release.yml` appends
# exactly one machine line `digest: sha256:...`; anything else in the body that
# looks like a digest is an ambiguity and a failed deploy, not a first match.
DIGEST_MARKERS=$(printf '%s' "$RELEASE" |
  grep -oE 'digest:[[:space:]]*sha256:[0-9a-f]{64}' || true)
DIGEST_MARKER_COUNT=$(printf '%s\n' "$DIGEST_MARKERS" | grep -c 'sha256:' || true)
DIGEST_STRINGS=$(printf '%s' "$RELEASE" | grep -oE 'sha256:[0-9a-f]{64}' || true)
DIGEST_STRING_COUNT=$(printf '%s\n' "$DIGEST_STRINGS" | grep -c 'sha256:' || true)
if [ "$DIGEST_MARKER_COUNT" -eq 0 ]; then
  fail "release v$VERSION has no published image digest"
fi
if [ "$DIGEST_MARKER_COUNT" -ne 1 ] || [ "$DIGEST_STRING_COUNT" -ne 1 ]; then
  fail "release v$VERSION must carry exactly one 'digest: sha256:...' line (found $DIGEST_MARKER_COUNT marker(s) and $DIGEST_STRING_COUNT sha256 string(s)); a digest in the tag message is ambiguous"
fi
DIGEST="sha256:${DIGEST_MARKERS#*sha256:}"

# The digest alone binds the tag to a registry object; only the signature binds
# it to this repository's release job. The public key is installed next to the
# env files, and a missing cosign is a failed deploy rather than a skipped check.
COSIGN_PUB="$APP_DIR/env/cosign.pub"
[ -f "$COSIGN_PUB" ] ||
  fail "release signature key $COSIGN_PUB is missing; cannot verify $DIGEST"
require_private_file "$COSIGN_PUB"
command -v cosign >/dev/null 2>&1 ||
  fail "cosign is required to verify $DIGEST"
if ! cosign verify --key "$COSIGN_PUB" "$REGISTRY_IMAGE@$DIGEST" >>"$LOG" 2>&1; then
  fail "cosign verify failed for $REGISTRY_IMAGE@$DIGEST"
fi
log "release v$VERSION resolves to $DIGEST and the signature verifies"

STEP="registry-login"
if [ -f "$TOKEN_FILE" ]; then
  podman login ghcr.io -u "${MAJADU_GHCR_USER:-hidaydev}" --password-stdin \
    <"$TOKEN_FILE" >>"$LOG" 2>&1 || fail "podman login ghcr.io failed"
else
  log "no GHCR token file; using the existing podman credentials"
fi

STEP="pull"
# A failed pull is a failed deploy. Falling back to :prev used to keep the old
# image running while the state files below recorded the release as deployed,
# and the version check then skipped every later push for that version. The
# service is left on :local instead, and the state files are not written.
if ! podman pull "$REGISTRY_IMAGE@$DIGEST" >>"$LOG" 2>&1; then
  log "ERROR: could not pull $REGISTRY_IMAGE@$DIGEST; v$VERSION is not deployed and :local was left untouched (step: $STEP)"
  alert
  exit 1
fi
log "pulled $REGISTRY_IMAGE@$DIGEST"

# ---------------------------------------------------------------------------
# Schema first, service second. The image carries db/migrations and dbtools, so
# the release that is about to run also migrates the database. `migrate` is a
# single transaction with an advisory lock, and `verify` then proves the ledger
# matches the committed files; either failure aborts here, while :local and
# :prev still point at the release that is running. The owner DSN is required
# because DDL needs bm2_owner, not the application role. No --allow-contract:
# a migration marked `-- contract` is refused here and applied by hand one
# release later, so a deploy can never be the step that removes the old shape.
# ---------------------------------------------------------------------------
# The previous release's schema is read before `migrate`: a later failure writes
# last-attempt.json and leaves last-release.json as the record of what runs.
PREV_SCHEMA=$(sed -n 's/.*"schema":"\([^"]*\)".*/\1/p' \
  "$STATE_DIR/last-release.json" 2>/dev/null | tail -1 || true)
[ -n "$PREV_SCHEMA" ] || PREV_SCHEMA="unknown"
STEP="migrate"
OWNER_DSN=$(sed -n 's/^MAJADU_OWNER_DSN=//p' "$TOOLS_ENV" | tail -1)
if [ -z "$OWNER_DSN" ]; then
  fail "MAJADU_OWNER_DSN is missing from $TOOLS_ENV; cannot migrate"
fi
if ! run_tool /usr/local/bin/dbtools "$OWNER_DSN" \
  migrate --dir /app/db/migrations >>"$LOG" 2>&1; then
  fail "dbtools migrate failed; v$VERSION is not deployed and the running release was left alone"
fi
STEP="verify-schema"
if ! run_tool /usr/local/bin/dbtools "$OWNER_DSN" \
  verify --dir /app/db/migrations >>"$LOG" 2>&1; then
  fail "dbtools verify failed; the database is not at the committed schema, v$VERSION is not deployed"
fi
# The last migration file is the schema this release expects. An empty name is
# not a version: without it the release record cannot say which schema the image
# needs, so the deploy stops instead of writing metadata that a later rollback
# or audit would have to guess at.
SCHEMA_FILE=$(ls "$MONO_DIR"/db/migrations/*.sql 2>/dev/null | tail -1 || true)
if [ -z "$SCHEMA_FILE" ] || [ ! -f "$SCHEMA_FILE" ]; then
  fail "cannot name the schema version: no migration file in $MONO_DIR/db/migrations"
fi
SCHEMA=$(basename "$SCHEMA_FILE" .sql)
log "schema verified at $SCHEMA"

STEP="rotate"
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

# ---------------------------------------------------------------------------
# Units come from the repository, not from whatever was left on the VPS.
# ---------------------------------------------------------------------------
STEP="sync-units"
# Quadlet reads .container files; services and timers are plain user units.
# Timers are installed but never enabled here: enabling is the operator's step
# in docs/ops/cutover.md, so a deploy cannot start a timer the runbook has not
# cleared yet.
for kind in container service timer; do
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
# The units are on disk; a reload failure would leave systemd running the old
# ones, so report it instead of hiding it.
if ! reload_out=$(service daemon-reload 2>&1); then
  log "WARNING: daemon-reload failed: $reload_out"
fi

# ---------------------------------------------------------------------------
# Operator scripts come from the repository too: cutover.sh calls backup.sh,
# restore.sh and smoke.sh from $APP_DIR/scripts/, so a fix that only lands in
# the checkout never reaches the VPS. Each file is syntax-checked before the
# move, and the swap is a rename, so a script is never half-written in place.
# ---------------------------------------------------------------------------
STEP="sync-scripts"
SCRIPTS_DIR="$APP_DIR/scripts"
mkdir -p "$SCRIPTS_DIR"
for SRC in "$MONO_DIR"/ops/scripts/*.sh; do
  [ -f "$SRC" ] || continue
  NAME=$(basename "$SRC")
  if cmp -s "$SRC" "$SCRIPTS_DIR/$NAME"; then
    continue
  fi
  # `sh -n` is the first gate. These scripts use `#!/usr/bin/env bash` and
  # arrays/local, which dash rejects even though they are valid for the shebang
  # interpreter, so bash is the fallback for a bash shebang. Neither passing
  # means nothing is moved.
  if ! sh -n "$SRC" 2>/dev/null; then
    if ! head -n 1 "$SRC" | grep -q 'bash' || ! bash -n "$SRC" 2>/dev/null; then
      fail "$NAME does not pass a syntax check"
    fi
  fi
  TMP="$SCRIPTS_DIR/$NAME.new.$$"
  install -m 755 "$SRC" "$TMP"
  mv -f "$TMP" "$SCRIPTS_DIR/$NAME"
  log "script $NAME updated from the repository"
done

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
  log "readiness gate failed; rolling back to :prev: schema $PREV_SCHEMA -> $SCHEMA (the schema is not rolled back, so :prev must still serve $SCHEMA)"
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

STEP="smoke"
# `/readyz` only proves the process is willing to serve. The smoke test proves
# the thing that was released is the thing answering: `/version` must report
# $VERSION, because a stale container that passed readiness would otherwise be
# recorded as this release.
if ! "$SCRIPTS_DIR/smoke.sh" "$HEALTH_URL" "$VERSION" >>"$LOG" 2>&1; then
  fail "smoke test failed for v$VERSION; see $LOG (the release is not recorded, so the next push retries it)"
fi

STEP="verify-image"
CONTAINER_IMAGE=$(podman inspect --format '{{.Image}}' "$SERVICE" 2>/dev/null || true)
LOCAL_ID=$(podman image inspect --format '{{.Id}}' "$LOCAL_IMAGE:local")
if [ -n "$CONTAINER_IMAGE" ] && [ "$CONTAINER_IMAGE" != "$LOCAL_ID" ]; then
  fail "container is not running the :local image"
fi

printf '%s\n' "$VERSION" | atomic_write "$STATE_DIR/deployed-version"
# release-rollback.sh needs the previous release's identity after this record is
# replaced; the image label is not guaranteed to carry it.
if [ -f "$STATE_DIR/last-release.json" ]; then
  cp -f "$STATE_DIR/last-release.json" "$STATE_DIR/last-release.json.prev"
fi
printf '{"version":"%s","commit":"%s","digest":"%s","schema":"%s","at":"%s"}\n' \
  "$VERSION" "$NEW_REV" "$DIGEST" "$SCHEMA" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" |
  atomic_write "$STATE_DIR/last-release.json"

# Retention: :local and :prev stay tagged, :v1-final is never touched, and
# everything the rotation left untagged goes away.
STEP="prune"
podman image prune -f >>"$LOG" 2>&1 || true

log "deployed v$VERSION ($DIGEST)"
