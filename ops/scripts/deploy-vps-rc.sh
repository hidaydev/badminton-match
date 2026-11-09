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
# MAJADU_RC_SKIP_GIT_SYNC, MAJADU_SERVICE_CMD, MAJADU_RC_CI_WAIT_ATTEMPTS,
# MAJADU_RC_CI_WAIT_SECONDS, MAJADU_RC_SKIP_CI_GATE.
#
# The host has no Nim toolchain, so QA-01 clause 3 cannot run `./task ci` here.
# The build is gated on the CI workflow instead: the newest run of ci.yml for the
# exact commit must be completed with success. A run that is queued or in
# progress is waited on while the deploy lock is held, because the webhook fires
# at push time, before GitHub has finished the workflow.
# `MAJADU_RC_SKIP_CI_GATE=1` is the documented emergency bypass and is recorded
# in last-release.json.
set -Eeuo pipefail

# The log holds request paths and share codes are bearer credentials, so every
# file these scripts create is private from the first byte instead of waiting for
# the hourly rotation to chmod it.
umask 077

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
TOOLS_ENV="$APP_DIR/env/majadu-rc-tools.env"
CI_TOKEN_FILE="$APP_DIR/env/github-token"
STATE_DIR="$APP_DIR/deploy"
LOG="$APP_DIR/logs/deploy.log"
LOCK_FILE="$APP_DIR/.deploy.lock"
CI_WAIT_ATTEMPTS="${MAJADU_RC_CI_WAIT_ATTEMPTS:-20}"
CI_WAIT_SECONDS="${MAJADU_RC_CI_WAIT_SECONDS:-15}"

STEP="start"
SCHEMA=""
CI_STATE="unchecked"

install -d -m 700 "$APP_DIR/logs" "$STATE_DIR"
: >>"$LOG"
chmod 600 "$LOG" 2>/dev/null || true

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOG"
}

json_field() {
  # A missing state file is the first deploy, not a failure. GNU sed exits 2 on
  # it, and `set -o pipefail` turned that into a failed `fail()` before its
  # message was written.
  [ -f "$1" ] || return 0
  sed -n "s/.*\"$2\":\"\([^\"]*\)\".*/\1/p" "$1" 2>/dev/null | head -1
}

# The running release record survives a failed attempt: the failure belongs in
# last-attempt.json, next to the version, schema and digest it was serving.
fail() {
  local run_version run_schema
  log "ERROR: $1 (step: $STEP)"
  run_version=$(json_field "$STATE_DIR/last-release.json" version)
  run_schema=$(json_field "$STATE_DIR/last-release.json" schema)
  : "${run_version:=${VERSION:-unknown}}"
  : "${run_schema:=${SCHEMA:-unknown}}"
  printf '{"step":"%s","ci":"%s","message":"%s","version":"%s","schema":"%s","at":"%s"}\n' \
    "$STEP" "$CI_STATE" "$1" "$run_version" "$run_schema" \
    "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    >"$STATE_DIR/last-attempt.json"
  exit 1
}

trap 'fail "command failed at line $LINENO"' ERR

file_mode() {
  stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null || echo "?"
}

file_owner() {
  stat -c '%u' "$1" 2>/dev/null || stat -f '%u' "$1" 2>/dev/null || echo "?"
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
# An empty commit cannot be gated: `head_sha=` would ask GitHub for nothing and
# `--build-arg APP_COMMIT=` would build an image no check can name. Fail here,
# before the gate and before podman.
[ -n "$COMMIT" ] ||
  fail "git rev-parse HEAD returned an empty commit; refusing to deploy"
VERSION=$(tr -d '[:space:]' <VERSION)
[ -n "$VERSION" ] || fail "VERSION is empty"

# The webhook runs the installed copy, so refresh it from the checkout it just
# synced. The incoming copy is host code on the next push, so it is checked
# before it becomes live: `bash -n` first, then an ownership check that refuses
# to replace a script (or a directory) the deploy user does not own. A failed
# check keeps the installed copy. Bash keeps reading the old inode, which is why
# the replace is atomic: this run keeps its own code and the next one starts
# from the branch.
STEP="self-install"
SELF_INSTALL="$APP_DIR/scripts/deploy-vps-rc.sh"
SELF_SRC="$MONO_DIR/ops/scripts/deploy-vps-rc.sh"
[ -f "$SELF_SRC" ] || fail "$SELF_SRC is missing from the checkout"
bash -n "$SELF_SRC" ||
  fail "$SELF_SRC does not pass bash -n; keeping the installed deploy script"
SELF_DIR=$(dirname "$SELF_INSTALL")
mkdir -p "$SELF_DIR"
[ "$(file_owner "$SELF_DIR")" = "$(id -u)" ] ||
  fail "$SELF_DIR is not owned by the deploy user; refusing to install $SELF_SRC"
if [ -f "$SELF_INSTALL" ]; then
  [ "$(file_owner "$SELF_INSTALL")" = "$(id -u)" ] ||
    fail "$SELF_INSTALL is not owned by the deploy user; refusing to replace it"
  cmp -s "$SELF_SRC" "$SELF_INSTALL" || {
    install -m 755 "$SELF_SRC" "$SELF_INSTALL.new.$$"
    mv -f "$SELF_INSTALL.new.$$" "$SELF_INSTALL"
    log "deploy script refreshed from the checkout; the next push runs it"
  }
else
  install -m 755 "$SELF_SRC" "$SELF_INSTALL.new.$$"
  mv -f "$SELF_INSTALL.new.$$" "$SELF_INSTALL"
  log "deploy script installed from the checkout; the next push runs it"
fi

# ---------------------------------------------------------------------------
# The env file is the only place the DSN lives. A missing or world-readable file
# is a failed deploy, not a reason to guess.
# ---------------------------------------------------------------------------
STEP="env-check"
[ -f "$ENV_FILE" ] || fail "env file $ENV_FILE is missing"
[ -f "$TOOLS_ENV" ] || fail "tool env file $TOOLS_ENV is missing"
for file in "$ENV_FILE" "$TOOLS_ENV"; do
  MODE=$(file_mode "$file")
  case "$MODE" in
    600|400) ;;
    *) fail "$file must be mode 600 (found $MODE)" ;;
  esac
done
# The unit loads only ENV_FILE; the owner DSN is a deploy secret and lives in
# the tool env, which the unit never reads.
OWNER_DSN=$(sed -n 's/^MAJADU_OWNER_DSN=//p' "$TOOLS_ENV" | tail -1)
APP_DSN=$(sed -n 's/^MAJADU_PG_DSN=//p' "$ENV_FILE" | tail -1)
[ -n "$OWNER_DSN" ] || fail "MAJADU_OWNER_DSN is missing from $TOOLS_ENV"
[ -n "$APP_DSN" ] || fail "MAJADU_PG_DSN is missing from $ENV_FILE"
# The role names are shared with the future bm2, so the database name is the
# only thing that keeps this instance away from production data. Refuse a file
# that points somewhere else instead of deploying it.
OWNER_DB=$(printf '%s' "$OWNER_DSN" | sed 's/.*\///' | cut -d'?' -f1)
APP_DB=$(printf '%s' "$APP_DSN" | sed 's/.*\///' | cut -d'?' -f1)
[ "$OWNER_DB" = "bm2_rc" ] || fail "MAJADU_OWNER_DSN points at '$OWNER_DB', not bm2_rc"
[ "$APP_DB" = "bm2_rc" ] || fail "MAJADU_PG_DSN points at '$APP_DB', not bm2_rc"

# This file is the RC unit's EnvironmentFile. An existing host that adds the
# tool file without deleting the old owner line would keep handing the owner
# credential to the RC API, so stop before the build and name the line.
# systemd skips leading whitespace, allows whitespace around `=`, and accepts an
# `export` prefix, so the match has to see those forms; comments do not match.
for key in MAJADU_OWNER_DSN MAJADU_ETL_DSN MAJADU_ETL_SOURCE_DSN MAJADU_BACKUP_DSN_BM2 \
  MAJADU_CUTOVER_RESTORE_DSN MAJADU_AUDIT_DSN; do
  if hit=$(grep -Ein "^[[:space:]]*(export[[:space:]]+)?${key}[[:space:]]*=" "$ENV_FILE"); then
    fail "$ENV_FILE:${hit%%:*} must not contain $key; move it to $TOOLS_ENV"
  fi
done

# ---------------------------------------------------------------------------
# CI gate (QA-01 clause 3). The host has no Nim toolchain, so `./task ci` cannot
# run here. The build is pinned to the CI workflow for this repository: the
# newest run of ci.yml for the exact commit must be completed with success.
# Every other workflow is ignored, so a Coverage or bot run cannot stand in for
# CI and an unrelated cancelled run cannot block a healthy commit. A run that is
# queued or in progress is waited on, because the webhook fires at push time and
# GitHub needs a moment to finish the workflow; the deploy lock is held for the
# whole wait. A redeploy of the commit that is already live skips the lookup,
# because it cannot introduce new code.
# ---------------------------------------------------------------------------
STEP="ci-gate"
CI_WORKFLOW="ci.yml"

case "$CI_WAIT_ATTEMPTS" in
  ''|*[!0-9]*) fail "MAJADU_RC_CI_WAIT_ATTEMPTS must be a whole number, got '$CI_WAIT_ATTEMPTS'" ;;
esac
case "$CI_WAIT_SECONDS" in
  ''|*[!0-9]*) fail "MAJADU_RC_CI_WAIT_SECONDS must be a whole number, got '$CI_WAIT_SECONDS'" ;;
esac
[ "$CI_WAIT_ATTEMPTS" -ge 1 ] ||
  fail "MAJADU_RC_CI_WAIT_ATTEMPTS must be at least 1"

live_commit() {
  local from_state from_image
  from_state=$(sed -n 's/.*"commit":"\([^"]*\)".*/\1/p' \
    "$STATE_DIR/last-release.json" 2>/dev/null | tail -1 || true)
  if [ -n "$from_state" ]; then
    printf '%s\n' "$from_state"
    return 0
  fi
  if podman image exists "$LOCAL_IMAGE:local" 2>/dev/null; then
    from_image=$(podman image inspect --format \
      '{{ index .Labels "org.opencontainers.image.revision" }}' \
      "$LOCAL_IMAGE:local" 2>/dev/null || true)
    [ -n "$from_image" ] && printf '%s\n' "$from_image"
  fi
  return 0
}

# The token travels on stdin as a curl config, so no file holds it and a signal
# between two steps cannot leave a copy on disk.
ci_query() {
  curl -fsS --max-time 20 \
    -H "Accept: application/vnd.github+json" \
    --config - "$CI_URL" 2>/dev/null <<EOF
header = "Authorization: Bearer $CI_TOKEN"
EOF
}

if [ "${MAJADU_RC_SKIP_CI_GATE:-0}" = "1" ]; then
  CI_STATE="bypassed"
  log "WARNING: MAJADU_RC_SKIP_CI_GATE=1: building $COMMIT without a CI result. Emergency use only; last-release.json records the bypass."
elif [ -n "$COMMIT" ] && [ "$(live_commit)" = "$COMMIT" ]; then
  CI_STATE="already-live"
  log "ci gate: $COMMIT is already the running release; no CI lookup needed"
else
  [ -f "$CI_TOKEN_FILE" ] ||
    fail "ci gate has no token at $CI_TOKEN_FILE; refusing to build $COMMIT (provision it mode 600, or set MAJADU_RC_SKIP_CI_GATE=1 for an emergency)"
  TOKEN_MODE=$(file_mode "$CI_TOKEN_FILE")
  case "$TOKEN_MODE" in
    600|400) ;;
    *) fail "$CI_TOKEN_FILE must be mode 600 (found $TOKEN_MODE)" ;;
  esac
  # `read`, not `cat`: under `set -x` the trace names the assignment and the
  # file, never the value. The emptiness check reads the file too, so the token
  # is never expanded into a traced command. A trailing newline is optional.
  grep -q '[^[:space:]]' "$CI_TOKEN_FILE" ||
    fail "$CI_TOKEN_FILE is empty; refusing to build"
  IFS= read -r CI_TOKEN <"$CI_TOKEN_FILE" || true
  CI_URL="https://api.github.com/repos/$GITHUB_REPO/actions/workflows/$CI_WORKFLOW/runs?head_sha=$COMMIT&per_page=100"

  attempt=1
  while :; do
    if ! CI_BODY=$(ci_query); then
      fail "ci gate cannot read $CI_WORKFLOW runs for $COMMIT from api.github.com; refusing to build"
    fi
    CI_COMPACT=$(printf '%s' "$CI_BODY" | tr -d '[:space:]')
    CI_TOTAL=$(printf '%s' "$CI_COMPACT" |
      sed -n 's/.*"total_count":\([0-9]*\).*/\1/p' | head -1 || true)
    case "$CI_TOTAL" in
      ''|*[!0-9]*)
        fail "ci gate: empty or malformed response for $COMMIT from api.github.com; refusing to build" ;;
    esac
    # per_page=100 is the maximum the API returns in one page. A larger count
    # would hide runs, and the newest run is the one that decides, so refuse
    # rather than guess.
    [ "$CI_TOTAL" -le 100 ] ||
      fail "ci gate: $CI_TOTAL $CI_WORKFLOW runs for $COMMIT exceed the 100-run page; refusing to decide on a hidden page"

    # Every workflow run object carries exactly one run_number. Counting them
    # against total_count catches a truncated body and a run object the parser
    # below would skip: without it, an older parseable run could decide.
    CI_RUN_OBJECTS=$(printf '%s' "$CI_COMPACT" |
      grep -o '"run_number":' | wc -l | tr -d ' ' || true)
    [ "$CI_RUN_OBJECTS" -eq "$CI_TOTAL" ] ||
      fail "ci gate: parsed $CI_RUN_OBJECTS of $CI_TOTAL $CI_WORKFLOW run objects for $COMMIT; refusing a partial response"

    # Pick the run with the highest id, not the first array element: a reordered
    # response or a force-push reset must not let an older success mask a newer
    # failure. Splitting at `{"id":` marks every object that starts with an id;
    # only the run objects carry `run_number`, so repository and head_commit
    # chunks are skipped. Quotes inside strings are JSON-escaped, so a crafted
    # title or commit message cannot inject a status or conclusion field.
    #
    # Limit: this still assumes a run object lists `id` before any nested
    # object. If that key order ever changes, the id read here belongs to the
    # first nested object, not the run, and the count guard cannot see it. The
    # schema has kept `id` first; a strict JSON parser would be the only way to
    # remove the assumption, and shell cannot do that without a new dependency.
    CI_NEWEST=$(printf '%s' "$CI_COMPACT" | sed 's/{"id":/\
{"id":/g' | awk '
      BEGIN { newest = -1 }
      /"run_number":/ {
        id = 0
        if (match($0, /"id":[0-9]+/))
          id = substr($0, RSTART + 5, RLENGTH - 5) + 0
        status = ""
        conclusion = ""
        if (match($0, /"status":"[a-z_]+"/))
          status = substr($0, RSTART + 10, RLENGTH - 11)
        if (match($0, /"conclusion":"[a-z_]+"/))
          conclusion = substr($0, RSTART + 14, RLENGTH - 15)
        else if (match($0, /"conclusion":null/))
          conclusion = ""
        if (id > newest) {
          newest = id
          newest_status = status
          newest_conclusion = conclusion
        }
      }
      END { printf "%s|%s\n", newest_status, newest_conclusion }
    ' || true)
    CI_STATUS=${CI_NEWEST%%|*}
    CI_CONCLUSION=${CI_NEWEST#*|}

    if [ -z "$CI_STATUS" ]; then
      CI_PENDING="no $CI_WORKFLOW run yet"
    elif [ "$CI_STATUS" != "completed" ]; then
      CI_PENDING="the newest $CI_WORKFLOW run is $CI_STATUS"
    elif [ -n "$CI_CONCLUSION" ] && [ "$CI_CONCLUSION" != "success" ]; then
      fail "ci gate: newest $CI_WORKFLOW run for $COMMIT ended as $CI_CONCLUSION; refusing to build"
    elif [ "$CI_CONCLUSION" != "success" ]; then
      fail "ci gate: newest $CI_WORKFLOW run for $COMMIT completed without a conclusion; refusing to build"
    else
      break
    fi

    if [ "$attempt" -ge "$CI_WAIT_ATTEMPTS" ]; then
      fail "ci gate: $CI_PENDING for $COMMIT after $attempt attempt(s) of ${CI_WAIT_SECONDS}s; refusing to build"
    fi
    log "ci gate: $CI_PENDING for $COMMIT; waiting ${CI_WAIT_SECONDS}s (attempt $attempt/$CI_WAIT_ATTEMPTS, deploy lock held)"
    sleep "$CI_WAIT_SECONDS"
    attempt=$((attempt + 1))
  done

  CI_STATE="passed"
  log "ci gate: $COMMIT passed $CI_WORKFLOW"
fi

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

# Seeds are skipped when their checksum is unchanged and re-applied when the
# file changes; every statement is `on conflict do nothing`, so operator edits
# survive and new rows land. Running this on every deploy is what keeps a new
# registry key from turning into a container that cannot boot: the registry is
# required at read time, and a missing key is a ConfigError, not a default.
STEP="seed"
run_tool /usr/local/bin/dbtools "$OWNER_DSN" \
  seed --dir /app/db/seeds >>"$LOG" 2>&1 ||
  fail "dbtools seed failed; the release was left alone"
log "applied the seed files"

# ---------------------------------------------------------------------------
# Unit comes from the repository, not from whatever was left on the VPS.
# ---------------------------------------------------------------------------
STEP="sync-unit"
UNIT_SRC="$MONO_DIR/ops/systemd/majadu-rc-api.container"
UNIT_DEST="$HOME/.config/containers/systemd/majadu-rc-api.container"
# The unit bind-mounts this path; podman refuses to start when it is missing.
mkdir -p "$APP_DIR/logs/main"
# Install the alert template first: if this fails, the run stops before the
# unit that references it is written, so the host never has a unit with
# OnFailure on disk and no template to start. The RC may share the production
# user manager (the template already exists) or have its own host, so install
# it from the repository either way.
ALERT_SRC="$MONO_DIR/ops/systemd/majadu-alert@.service"
ALERT_DEST="$HOME/.config/systemd/user/majadu-alert@.service"
mkdir -p "$(dirname "$ALERT_DEST")"
if ! cmp -s "$ALERT_SRC" "$ALERT_DEST"; then
  install -m 644 "$ALERT_SRC" "$ALERT_DEST"
  log "unit majadu-alert@.service updated from the repository"
fi
mkdir -p "$(dirname "$UNIT_DEST")"
if ! cmp -s "$UNIT_SRC" "$UNIT_DEST"; then
  install -m 644 "$UNIT_SRC" "$UNIT_DEST"
  log "unit majadu-rc-api.container updated from the repository"
fi
# Always reload: the quadlet generator only creates the .service when it runs, so
# a unit file that was already in place (bootstrap installs it) never becomes a
# startable unit otherwise. A failed reload cannot be silent: the new units are
# on disk but systemd is still running the old ones.
if ! reload_out=$(service daemon-reload 2>&1); then
  log "WARNING: daemon-reload failed: $reload_out"
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

printf '{"version":"%s","commit":"%s","schema":"%s","branch":"%s","ci":"%s","web":"%s","at":"%s"}\n' \
  "$VERSION" "$COMMIT" "$SCHEMA" "$BRANCH" "$CI_STATE" "$WEB_URL" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
  >"$STATE_DIR/last-release.json"

# Retention: only :local and :prev stay tagged; everything the rotation left
# untagged goes away. No commit-SHA tags are created anywhere.
STEP="prune"
podman image prune -f >>"$LOG" 2>&1 || true

log "deployed $COMMIT (v$VERSION, schema $SCHEMA)"