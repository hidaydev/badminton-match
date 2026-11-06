#!/usr/bin/env bash
# One-time bootstrap of the RC database from a copy of production.
#
#   ./ops/scripts/bootstrap-rc.sh            # refuse if bm2_rc already has data
#   ./ops/scripts/bootstrap-rc.sh --force    # drop and rebuild bm2_rc
#
# This never touches production. It reads `bm` through pg_dump, restores the
# dump into a scratch database, and lets the importer write `bm2_rc` — the same
# chain cutover.sh uses (dump -> staging -> import -> verify), just aimed at the
# RC instead of bm2.
#
# The host has no psql/pg_dump, so every database call runs inside the
# qouver-postgres container. That is also what makes this safe to run as a
# normal user: no system packages, no sudo.
#
# Env:
#   MAJADU_RC_APP_DIR   default /srv/qouver/apps/majadu-rc
#   MAJADU_RC_IMAGE     default localhost/majadu-rc-api
#   MAJADU_RC_BRANCH    default release/2.0.0-rc.1
#   MAJADU_RC_PG        default qouver-postgres
#   MAJADU_RC_PG_SUPER  default qouver (the container's POSTGRES_USER)
#   V1_DSN              source database; default read from the v1 env file
#   MAJADU_OWNER_SUB    Google subject of the platform owner (optional)
#   MAJADU_OWNER_EMAIL  email of that account (optional)
set -euo pipefail

FORCE=0
[ "${1:-}" = "--force" ] && FORCE=1

APP_DIR="${MAJADU_RC_APP_DIR:-/srv/qouver/apps/majadu-rc}"
LOCAL_IMAGE="${MAJADU_RC_IMAGE:-localhost/majadu-rc-api}"
GITHUB_REPO="${MAJADU_GITHUB_REPO:-hidaydev/badminton-match}"
BRANCH="${MAJADU_RC_BRANCH:-release/2.0.0-rc.1}"
PG="${MAJADU_RC_PG:-qouver-postgres}"
PG_SUPER="${MAJADU_RC_PG_SUPER:-qouver}"
NETWORK="${MAJADU_RC_NETWORK:-qouver}"
ENV_FILE="$APP_DIR/env/majadu-rc.env"
MONO_DIR="$APP_DIR/repo"
STATE_DIR="$APP_DIR/deploy"
BACKUP_DIR="$APP_DIR/backups"
STAGING_DB="bm_restore_rc"

log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
die() { printf 'bootstrap-rc: %s\n' "$*" >&2; exit 1; }

mkdir -p "$APP_DIR/logs" "$STATE_DIR" "$BACKUP_DIR"

[ -f "$ENV_FILE" ] || die "$ENV_FILE is missing; copy ops/env/rc.env.example and fill it in"
MODE=$(stat -c '%a' "$ENV_FILE" 2>/dev/null || stat -f '%Lp' "$ENV_FILE")
case "$MODE" in 600|400) ;; *) die "$ENV_FILE must be mode 600 (found $MODE)" ;; esac

OWNER_DSN=$(sed -n 's/^MAJADU_OWNER_DSN=//p' "$ENV_FILE" | tail -1)
APP_DSN=$(sed -n 's/^MAJADU_PG_DSN=//p' "$ENV_FILE" | tail -1)
[ -n "$OWNER_DSN" ] || die "MAJADU_OWNER_DSN is missing from $ENV_FILE"
[ -n "$APP_DSN" ] || die "MAJADU_PG_DSN is missing from $ENV_FILE"

dsn_part() { # dsn_part <dsn> <user|password|database>
  local dsn="$1" rest userinfo
  rest="${dsn#*://}"
  userinfo="${rest%%@*}"
  case "$2" in
    user) printf '%s' "${userinfo%%:*}" ;;
    password) printf '%s' "${userinfo#*:}" ;;
    database) printf '%s' "${dsn##*/}" | cut -d'?' -f1 ;;
    *) die "dsn_part: unknown field $2" ;;
  esac
}

quote_sql() { printf "%s" "${1//\'/\'\'}"; }

OWNER_ROLE=$(dsn_part "$OWNER_DSN" user)
OWNER_PASS=$(dsn_part "$OWNER_DSN" password)
APP_ROLE=$(dsn_part "$APP_DSN" user)
APP_PASS=$(dsn_part "$APP_DSN" password)
RC_DB=$(dsn_part "$OWNER_DSN" database)

psql_db() {
  local db="$1"
  shift
  podman exec -i "$PG" psql -U "$PG_SUPER" -d "$db" -v ON_ERROR_STOP=1 "$@"
}
psql_super() { psql_db postgres "$@"; }

case "$RC_DB" in
  bm|bm2|majadu|postgres) die "refusing to bootstrap over '$RC_DB'; use a dedicated RC database" ;;
  *) ;;
esac

# The RC shares the bm2_* role names because every migration grants to bm2_app
# by name. That is safe only while bm2 does not exist: this script sets the
# passwords on those roles, which would break production once it does.
if psql_super -Atc "select 1 from pg_database where datname = 'bm2'" | grep -q 1; then
  die "database bm2 exists; this script would reset the production role passwords. Dismantle the RC or give it dedicated roles first."
fi

log "RC database is $RC_DB (roles $OWNER_ROLE/$APP_ROLE)"

# ---------------------------------------------------------------------------
# Checkout, so the image and the migrations come from the branch being tested.
# ---------------------------------------------------------------------------
log "syncing $BRANCH"
if [ -d "$MONO_DIR/.git" ]; then
  git -C "$MONO_DIR" fetch origin "$BRANCH" >/dev/null 2>&1
  git -C "$MONO_DIR" reset --hard "origin/$BRANCH" >/dev/null 2>&1
else
  git clone "https://github.com/$GITHUB_REPO.git" "$MONO_DIR" >/dev/null 2>&1
  git -C "$MONO_DIR" checkout -B "$BRANCH" "origin/$BRANCH" >/dev/null 2>&1
fi
COMMIT=$(git -C "$MONO_DIR" rev-parse HEAD)
VERSION=$(tr -d '[:space:]' <"$MONO_DIR/VERSION")
log "building $LOCAL_IMAGE:local at $COMMIT"
podman build -f "$MONO_DIR/apps/api/Dockerfile" \
  --build-arg APP_VERSION="$VERSION" \
  --build-arg APP_COMMIT="$COMMIT" \
  -t "$LOCAL_IMAGE:local" "$MONO_DIR" >/dev/null

run_tool() {
  local entry="$1" dsn="$2"
  shift 2
  podman run --rm --network "$NETWORK" -e MAJADU_PG_DSN="$dsn" \
    --entrypoint "$entry" "$LOCAL_IMAGE:local" "$@"
}

# ---------------------------------------------------------------------------
# Refuse to overwrite a database that someone has already used.
# ---------------------------------------------------------------------------
EXISTS=$(psql_super -Atc "select 1 from pg_database where datname = '$RC_DB'")
if [ -n "$EXISTS" ]; then
  USED=$(run_tool /usr/local/bin/dbtools "$OWNER_DSN" verify --dir /app/db/migrations >/dev/null 2>&1 && echo yes || echo no)
  if [ "$USED" = "yes" ] && [ "$FORCE" != "1" ]; then
    log "$RC_DB already carries the RC schema; pass --force to drop and rebuild it"
    exit 0
  fi
  if [ "$FORCE" = "1" ]; then
    log "dropping $RC_DB"
    psql_super -c "drop database if exists $RC_DB with (force)"
  fi
fi

# ---------------------------------------------------------------------------
# Roles and database. The role names carry _rc so a wrong DSN fails to connect
# instead of reaching bm2 during the real cutover.
# ---------------------------------------------------------------------------
log "creating roles and $RC_DB"
psql_super <<SQL
do \$\$
begin
  if not exists (select 1 from pg_roles where rolname = '$(quote_sql "$OWNER_ROLE")') then
    create role $(quote_sql "$OWNER_ROLE") login password '$(quote_sql "$OWNER_PASS")';
  else
    alter role $(quote_sql "$OWNER_ROLE") with login password '$(quote_sql "$OWNER_PASS")';
  end if;
  if not exists (select 1 from pg_roles where rolname = '$(quote_sql "$APP_ROLE")') then
    create role $(quote_sql "$APP_ROLE") login password '$(quote_sql "$APP_PASS")';
  else
    alter role $(quote_sql "$APP_ROLE") with login password '$(quote_sql "$APP_PASS")';
  end if;
  -- 0015 grants to bm2_etl; the RC never connects as it, so it stays nologin.
  if not exists (select 1 from pg_roles where rolname = 'bm2_etl') then
    create role bm2_etl nologin;
  end if;
end \$\$;
SQL

if [ -z "$EXISTS" ] || [ "$FORCE" = "1" ]; then
  psql_super -c "create database $RC_DB owner $(quote_sql "$OWNER_ROLE")"
fi
psql_super -c "revoke connect on database $RC_DB from public"
psql_super -c "grant connect on database $RC_DB to $(quote_sql "$APP_ROLE")"
psql_db "$RC_DB" -c "grant usage on schema public to $(quote_sql "$APP_ROLE")"

run_tool /usr/local/bin/dbtools "$OWNER_DSN" migrate --dir /app/db/migrations
run_tool /usr/local/bin/dbtools "$OWNER_DSN" seed --dir /app/db/seeds

# ---------------------------------------------------------------------------
# Copy production data through the same chain the cutover uses.
# ---------------------------------------------------------------------------
V1_DSN="${V1_DSN:-$(sed -n 's/^DATABASE_URL=//p' /srv/qouver/apps/majadu/env/majadu-prod.env 2>/dev/null | tail -1)}"
[ -n "$V1_DSN" ] || die "V1_DSN is empty and the v1 env file could not be read"
V1_DB=$(dsn_part "$V1_DSN" database)
[ "$V1_DB" != "$RC_DB" ] || die "source and target are the same database ($V1_DB)"

STAMP=$(date -u '+%Y%m%dT%H%M%SZ')
DUMP="$BACKUP_DIR/$V1_DB-rc-$STAMP.dump"
log "dumping $V1_DB to $DUMP"
podman exec "$PG" pg_dump -U "$PG_SUPER" -Fc "$V1_DB" >"$DUMP"
chmod 600 "$DUMP"
podman exec "$PG" pg_restore -l "$DUMP" >/dev/null 2>&1 ||
  die "the dump cannot be read back; refusing to import a truncated file"

log "restoring into $STAGING_DB"
psql_super -c "drop database if exists $STAGING_DB with (force)"
psql_super -c "create database $STAGING_DB"
podman exec -i "$PG" pg_restore -U "$PG_SUPER" -d "$STAGING_DB" \
  --no-owner --no-privileges <"$DUMP"

STAGING_DSN="postgres://$OWNER_ROLE:$(printf '%s' "$OWNER_PASS" | sed 's/@/%40/g')@$PG:5432/$STAGING_DB"
psql_super -c "grant connect on database $STAGING_DB to $(quote_sql "$OWNER_ROLE")" >/dev/null
# pg_restore ran as the container superuser with --no-owner, so the owner role
# needs an explicit read grant before the importer can open the source.
psql_db "$STAGING_DB" <<SQL
grant usage on schema public to $(quote_sql "$OWNER_ROLE");
grant select on all tables in schema public to $(quote_sql "$OWNER_ROLE");
SQL

log "importing $STAGING_DB into $RC_DB"
run_tool /usr/local/bin/majadu-import "$OWNER_DSN" \
  etl --source "$STAGING_DSN" --target "$OWNER_DSN" --slug majadu --name Majadu
run_tool /usr/local/bin/majadu-import "$OWNER_DSN" \
  verify --source "$STAGING_DSN" --target "$OWNER_DSN" --slug majadu

if [ -n "${MAJADU_OWNER_SUB:-}" ]; then
  log "seeding the platform owner"
  if [ -n "${MAJADU_OWNER_EMAIL:-}" ]; then
    run_tool /usr/local/bin/ownerseed "$OWNER_DSN" \
      --sub "$MAJADU_OWNER_SUB" --email "$MAJADU_OWNER_EMAIL"
  else
    run_tool /usr/local/bin/ownerseed "$OWNER_DSN" --sub "$MAJADU_OWNER_SUB"
  fi
else
  log "MAJADU_OWNER_SUB is not set; run ownerseed before testing admin screens"
fi

date -u '+%Y-%m-%dT%H:%M:%SZ' >"$STATE_DIR/seeded"
log "dropping staging database $STAGING_DB"
psql_super -c "drop database if exists $STAGING_DB with (force)"

# The deploy script is installed from the repository, like every other operator
# script, so a fix that only lands in the checkout never stays behind.
mkdir -p "$APP_DIR/scripts" "$APP_DIR/caddy"
install -m 755 "$MONO_DIR/ops/scripts/deploy-vps-rc.sh" "$APP_DIR/scripts/deploy-vps-rc.sh"
install -m 644 "$MONO_DIR/ops/caddy/site-rc.caddy" "$APP_DIR/caddy/site-rc.caddy"
install -m 644 "$MONO_DIR/ops/systemd/majadu-rc-api.container" \
  "$HOME/.config/containers/systemd/majadu-rc-api.container"

log "RC database ready; starting the service through the normal deploy path"
MAJADU_RC_SKIP_GIT_SYNC=1 "$APP_DIR/scripts/deploy-vps-rc.sh" badminton-match "refs/heads/$BRANCH"

cat <<EOF

Next steps that need root or the dashboard:

1. Caddy (sudo):
     sudo install -o root -g root -m 644 $APP_DIR/repo/ops/caddy/site-rc.caddy /etc/caddy/site-rc.caddy
   add this line inside the api.qouver.com site block, then restart
     import /etc/caddy/site-rc.caddy
     sudo caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
     sudo systemctl restart caddy

2. Vercel: create project majadu-rc from $GITHUB_REPO,
   production branch $BRANCH, root directory apps/web.

3. Google: add https://majadu-rc.vercel.app/api/auth/callback
   to the OAuth client's Authorized redirect URIs.
EOF