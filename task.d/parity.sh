#!/bin/sh
# Parity corpus for the v1 API: record against a live v1 server, replay, verify.
# Cases live in testdata/parity/v1 and are described by cases.tsv.
. "$(dirname "$0")/lib.sh"

CASES_DIR="$REPO_ROOT/testdata/parity/v1"
SPEC="$CASES_DIR/cases.tsv"
MANIFEST="$CASES_DIR/MANIFEST.sha256"
ROUTES="$REPO_ROOT/apps/api/cmd/server/main.go"
BASE=${PARITY_BASE:-http://127.0.0.1:8091}

usage() {
  cat <<'EOF'
Usage: ./task parity <record|replay|verify> [options]

  record [CASE_OPTIONS]  capture every case in cases.tsv, or one case:
                         --name N --path P [--method M] [--route R]
                         [--header "Name: value"] [--body B | --body-file F]
  replay [NAME...]       replay all cases (or the named ones) and diff
  verify                 check MANIFEST.sha256 and corpus invariants

Options: --base URL (default $PARITY_BASE or http://127.0.0.1:8091)

Recording needs a freshly seeded v1 server:
  ./task dev-v1
  (cd apps/api && DATABASE_URL=postgresql://$(whoami)@127.0.0.1:5432/bm_v1_dev \
    MAJADU_DB_SCHEMA=bm MAJADU_ENV=dev PORT=8091 MAJADU_ADMIN_TOKEN=test-admin \
    go run ./cmd/server)
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
  _tmp="$MANIFEST.tmp"
  (
    cd "$CASES_DIR" || exit 1
    find . -name '*.json' -type f | LC_ALL=C sort | xargs $SHA_TOOL $SHA_OPTS
  ) > "$_tmp" || fail "failed to hash the corpus"
  mv "$_tmp" "$MANIFEST"
  printf 'parity: manifest updated: %s (%s cases)\n' \
    "$MANIFEST" "$(wc -l < "$MANIFEST" | tr -d ' ')"
}

check_manifest() {
  [ -f "$MANIFEST" ] || fail "missing manifest: $MANIFEST"
  (
    cd "$CASES_DIR" || exit 1
    $SHA_TOOL $SHA_OPTS -c MANIFEST.sha256 >/dev/null
  ) || fail "corpus drift: files differ from MANIFEST.sha256 (re-record or fix the change)"
  _listed=$(wc -l < "$MANIFEST" | tr -d ' ')
  _present=$(find "$CASES_DIR" -name '*.json' -type f | wc -l | tr -d ' ')
  [ "$_listed" -eq "$_present" ] ||
    fail "manifest lists $_listed cases but $_present case files exist"
  printf 'parity: manifest ok (%s cases)\n' "$_present"
}

[ "$#" -ge 1 ] || { usage >&2; exit 2; }
subcommand=$1
shift

pick_sha_tool

case "$subcommand" in
  record)
    _binary=$(parity_bin)
    if [ "$#" -eq 0 ]; then
      "$_binary" record --dir "$CASES_DIR" --base "$BASE" --spec "$SPEC"
    else
      "$_binary" record --dir "$CASES_DIR" --base "$BASE" "$@"
    fi
    write_manifest
    ;;
  replay)
    _binary=$(parity_bin)
    "$_binary" replay --dir "$CASES_DIR" --base "$BASE" "$@"
    ;;
  verify)
    check_manifest
    _binary=$(parity_bin)
    "$_binary" lint --dir "$CASES_DIR" --routes "$ROUTES"
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
