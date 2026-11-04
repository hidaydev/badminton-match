#!/bin/sh
# Parity corpora.
#
# v1 (the default) replays golden captures of the Go API against a live server.
# v2 records and replays the Nim API per contract operation, and checks the
# fixture-state fingerprint in testdata/parity/v2/state.json.
. "$(dirname "$0")/lib.sh"

V1_DIR="$REPO_ROOT/testdata/parity/v1"
V1_SPEC="$V1_DIR/cases.tsv"
V1_MANIFEST="$V1_DIR/MANIFEST.sha256"
V2_DIR="$REPO_ROOT/testdata/parity/v2"
V2_BASE_DEFAULT="http://127.0.0.1:18092"
V2_DB_DEFAULT="bm2_parity_v2"
ROUTES_GO="$REPO_ROOT/apps/api/cmd/server/main.go"
ROUTES_NIM="$REPO_ROOT/apps/api/src/routes_gen.nim"
BASE=${PARITY_BASE:-http://127.0.0.1:8091}
# Local development key only; it is the same fixture key r0-demo uses.
DEFAULT_SHARE_KEYS='{"1":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="}'

usage() {
  cat <<'EOF'
Usage: ./task parity <record|replay|verify> [options]      # v1 (default)
       ./task parity v2 <record|replay|lint|reset|state|verify> [options]

v1:
  record [CASE_OPTIONS]  capture every case in cases.tsv, or one case:
                         --name N --path P [--method M] [--route R]
                         [--header "Name: value"] [--body B | --body-file F]
  replay [NAME...]       replay all cases (or the named ones) and diff
  verify                 check MANIFEST.sha256 and corpus invariants

v2:
  reset                  rebuild the fixture in PARITY_V2_DSN
  record                 reset, replay-free capture of cases.tsv, state snapshot
  replay                 replay cases.tsv in order against PARITY_V2_BASE
  lint                   manifest + one case per contract operation + invariants
  state                  compare state.json and run the mutation self-test
  verify                 everything above end to end on a disposable database

Options: --base URL (default $PARITY_BASE or http://127.0.0.1:8091)
v2 environment: PARITY_V2_DSN (default local bm2_parity_v2),
                PARITY_V2_BASE (default http://127.0.0.1:18092),
                SHARE_CODE_KEYS / SHARE_CODE_ACTIVE_KEY_ID.
EOF
}

pick_sha_tool() {
  if command -v shasum >/dev/null 2>&1; then
    SHA_TOOL=shasum
    SHA_OPTS="-a 256"
  elif command -v sha256sum >/dev/null 2>&1; then
    SHA_TOOL=sha256sum
    SHA_OPTS=""
  else
    fail "shasum or sha256sum is required"
  fi
}

parity_bin() {
  if [ -n "${PARITY_BIN:-}" ]; then
    printf '%s\n' "$PARITY_BIN"
    return
  fi
  _binary=$(test_binary "$REPO_ROOT/tools/parity/main.nim")
  nim_build -o:"$_binary" "$REPO_ROOT/tools/parity/main.nim" >/dev/null
  printf '%s\n' "$_binary"
}

write_manifest() {
  cases_dir=$1
  manifest=$2
  _tmp="$manifest.tmp"
  (
    cd "$cases_dir" || exit 1
    find . -name '*.json' -type f | LC_ALL=C sort | xargs $SHA_TOOL $SHA_OPTS
  ) > "$_tmp" || fail "failed to hash the corpus"
  mv "$_tmp" "$manifest"
  printf 'parity: manifest updated: %s (%s files)\n' \
    "$manifest" "$(wc -l < "$manifest" | tr -d ' ')"
}

check_manifest() {
  cases_dir=$1
  manifest=$2
  [ -f "$manifest" ] || fail "missing manifest: $manifest"
  (
    cd "$cases_dir" || exit 1
    $SHA_TOOL $SHA_OPTS -c "$(basename "$manifest")" >/dev/null
  ) || fail "corpus drift: files differ from $(basename "$manifest")"
  _listed=$(wc -l < "$manifest" | tr -d ' ')
  _present=$(find "$cases_dir" -name '*.json' -type f | wc -l | tr -d ' ')
  [ "$_listed" -eq "$_present" ] ||
    fail "manifest lists $_listed files but $_present exist"
  printf 'parity: manifest ok (%s files)\n' "$_present"
}

# v2

v2_dsn() {
  if [ -n "${PARITY_V2_DSN:-}" ]; then
    printf '%s\n' "$PARITY_V2_DSN"
  else
    printf 'postgresql://%s@127.0.0.1:5432/%s\n' "$(whoami)" "$V2_DB_DEFAULT"
  fi
}

# The v2 verify command rebuilds the fixture, so it must never point at a
# database that holds something worth keeping.
v2_guard_dsn() {
  dsn=$1
  case "$dsn" in
    */bm2_dev|*/bm2_template|*/bm2_r0|*/postgres)
      fail "refusing to reset $dsn; point PARITY_V2_DSN at a disposable database" ;;
  esac
}

v2_prepare_db() {
  dsn=$1
  if [ -z "${PARITY_V2_DSN:-}" ]; then
    _exists=$(psql -d postgres -tAc \
      "select 1 from pg_database where datname = '$V2_DB_DEFAULT'" 2>/dev/null || true)
    if [ "$_exists" != "1" ]; then
      createdb "$V2_DB_DEFAULT" || fail "cannot create $V2_DB_DEFAULT"
    fi
  fi
  _dbtools=$(test_binary "$REPO_ROOT/tools/dbtools/main.nim")
  nim c $CHECK_FLAGS --nimcache:"$NIMCACHE_CHECK" -o:"$_dbtools" \
    "$REPO_ROOT/tools/dbtools/main.nim" >/dev/null
  MAJADU_PG_DSN="$dsn" "$_dbtools" migrate --dir "$REPO_ROOT/db/migrations" >/dev/null
  MAJADU_PG_DSN="$dsn" "$_dbtools" seed --dir "$REPO_ROOT/db/seeds" >/dev/null
}

v2_reset() {
  dsn=$1
  v2_guard_dsn "$dsn"
  _binary=$(parity_bin)
  SHARE_CODE_KEYS=${SHARE_CODE_KEYS:-$DEFAULT_SHARE_KEYS} \
    SHARE_CODE_ACTIVE_KEY_ID=${SHARE_CODE_ACTIVE_KEY_ID:-1} \
    "$_binary" reset --dir "$V2_DIR" --dsn "$dsn"
}

v2_state() {
  dsn=$1
  _binary=$(parity_bin)
  "$_binary" state-check --dir "$V2_DIR" --dsn "$dsn"
  "$_binary" state-selftest --dir "$V2_DIR" --dsn "$dsn"
}

v2_lint() {
  check_manifest "$V2_DIR" "$V2_DIR/MANIFEST.sha256"
  _binary=$(parity_bin)
  "$_binary" lint --dir "$V2_DIR" --routes "$ROUTES_NIM"
}

v2_replay() {
  base=$1
  _binary=$(parity_bin)
  "$_binary" replay --dir "$V2_DIR" --base "$base" \
    --spec "$V2_DIR/cases.tsv"
}

v2_boot_api() {
  dsn=$1
  base=$2
  port=$(printf '%s' "$base" | sed -E 's|^https?://[^:/]+:([0-9]+).*|\1|')
  case "$port" in
    ''|*[!0-9]*) fail "cannot read a port from $base" ;;
  esac
  if curl -fsS --max-time 1 "$base/healthz" >/dev/null 2>&1; then
    fail "$base already has a server; stop it or set PARITY_V2_BASE"
  fi
  sh "$REPO_ROOT/task.d/build.sh" >/dev/null
  _api="$REPO_ROOT/.cache/$WORKTREE/bin/majadu-api"
  _log="${TMPDIR:-/tmp}/parity-v2-api.log"
  _keys=${SHARE_CODE_KEYS:-$DEFAULT_SHARE_KEYS}
  _keyid=${SHARE_CODE_ACTIVE_KEY_ID:-1}
  MAJADU_PG_DSN="$dsn" MAJADU_PORT="$port" MAJADU_DRAIN_MS=0 MAJADU_ENV=dev \
    SHARE_CODE_KEYS="$_keys" SHARE_CODE_ACTIVE_KEY_ID="$_keyid" \
    OIDC_AUTHORIZE_URL="http://127.0.0.1:1/authorize" \
    OIDC_TOKEN_URL="http://127.0.0.1:1/token" \
    OIDC_JWKS_URL="http://127.0.0.1:1/jwks" \
    OIDC_ISSUER="http://127.0.0.1:1" \
    OIDC_CLIENT_ID="majadu-parity" \
    OIDC_REDIRECT_URI="$base/auth/callback" \
    "$_api" >"$_log" 2>&1 &
  API_PID=$!
  _waited=0
  while [ "$_waited" -lt 50 ]; do
    if curl -fsS --max-time 1 "$base/healthz" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.1
    _waited=$((_waited + 1))
  done
  tail -20 "$_log" >&2 || true
  fail "the API did not become healthy on $base"
}

v2_cleanup() {
  if [ -n "${API_PID:-}" ]; then
    kill "$API_PID" 2>/dev/null || true
    wait "$API_PID" 2>/dev/null || true
    API_PID=""
  fi
}

v2_verify() {
  require_cmd psql
  require_cmd createdb
  require_cmd curl
  dsn=$(v2_dsn)
  base=${PARITY_V2_BASE:-$V2_BASE_DEFAULT}
  v2_guard_dsn "$dsn"
  v2_lint
  v2_prepare_db "$dsn"
  v2_reset "$dsn"
  v2_boot_api "$dsn" "$base"
  trap v2_cleanup EXIT INT TERM
  v2_replay "$base"
  v2_state "$dsn"
  v2_cleanup
  trap - EXIT INT TERM
  printf 'parity: v2 ok\n'
}

v2_main() {
  [ "$#" -ge 1 ] || { usage >&2; exit 2; }
  action=$1
  shift
  dsn=$(v2_dsn)
  base=${PARITY_V2_BASE:-$V2_BASE_DEFAULT}
  case "$action" in
    reset)
      v2_reset "$dsn"
      ;;
    record)
      v2_guard_dsn "$dsn"
      v2_reset "$dsn"
      _binary=$(parity_bin)
      "$_binary" record --dir "$V2_DIR" --base "$base" --spec "$V2_DIR/cases.tsv"
      "$_binary" state-snapshot --dir "$V2_DIR" --dsn "$dsn"
      write_manifest "$V2_DIR" "$V2_DIR/MANIFEST.sha256"
      ;;
    replay)
      v2_replay "$base"
      ;;
    lint)
      v2_lint
      ;;
    state)
      v2_guard_dsn "$dsn"
      v2_state "$dsn"
      ;;
    verify)
      v2_verify
      ;;
    -h|--help|help)
      usage
      ;;
    *)
      printf 'Unknown v2 parity subcommand: %s\n\n' "$action" >&2
      usage >&2
      exit 2
      ;;
  esac
}

[ "$#" -ge 1 ] || { usage >&2; exit 2; }
subcommand=$1
shift

pick_sha_tool

if [ "$subcommand" = "v2" ]; then
  v2_main "$@"
  exit $?
fi

case "$subcommand" in
  record)
    _binary=$(parity_bin)
    if [ "$#" -eq 0 ]; then
      "$_binary" record --dir "$V1_DIR" --base "$BASE" --spec "$V1_SPEC"
    else
      "$_binary" record --dir "$V1_DIR" --base "$BASE" "$@"
    fi
    write_manifest "$V1_DIR" "$V1_MANIFEST"
    ;;
  replay)
    _binary=$(parity_bin)
    "$_binary" replay --dir "$V1_DIR" --base "$BASE" "$@"
    ;;
  verify)
    check_manifest "$V1_DIR" "$V1_MANIFEST"
    _binary=$(parity_bin)
    "$_binary" lint --dir "$V1_DIR" --routes "$ROUTES_GO"
    ;;
  -h|--help|help)
    usage
    ;;
  *)
    printf 'Unknown parity subcommand: %s\n\n' "$subcommand" >&2
    usage >&2
    exit 2
    ;;
esac
