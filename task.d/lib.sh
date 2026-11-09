#!/bin/sh
# Shared helpers for task.d/*.sh. Sourced, never executed directly.
set -eu

: "${REPO_ROOT:?REPO_ROOT is not set; run through ./task}"
: "${WORKTREE:?WORKTREE is not set; run through ./task}"
: "${NIMCACHE_CHECK:?NIMCACHE_CHECK is not set; run through ./task}"
: "${NIMCACHE_BUILD:?NIMCACHE_BUILD is not set; run through ./task}"

BUILD_FLAGS="-d:release --opt:speed --stackTrace:on --lineTrace:on --threads:on --mm:atomicArc"
CHECK_FLAGS="--hints:off"

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "required command not found: $1"
}

# Wall clock in milliseconds. `perl` is on macOS and on the GitHub runner, and
# the fallback keeps the script working where it is absent, at one second
# resolution: a slow suite is still visible, a fast one records 0.
now_ms() {
  if command -v perl >/dev/null 2>&1; then
    perl -MTime::HiRes=time -e 'printf "%.0f\n", time * 1000'
  else
    _s=$(date +%s)
    printf '%s\n' $((_s * 1000))
  fi
}

# A run that approaches the 15 minute job contract must say so before it hits
# it, not after. 720 seconds is the threshold; the contract itself is unchanged.
BUDGET_WARN_SECONDS=720

timing_begin() {
  # One TSV per target, so `test` and `coverage` never interleave rows:
  # <suite>\t<milliseconds>\t<status>
  TIMING_DIR="$REPO_ROOT/.cache/$WORKTREE/timing"
  mkdir -p "$TIMING_DIR"
  TIMING_FILE="$TIMING_DIR/$1.tsv"
  : >"$TIMING_FILE"
  RUN_STARTED_MS=$(now_ms)
}

timing_add() {
  printf '%s\t%s\t%s\n' "$1" "$2" "$3" >>"$TIMING_FILE"
}

timing_summary() {
  _elapsed=$(( ($(now_ms) - RUN_STARTED_MS) / 1000 ))
  printf '%s: %s seconds (timing: %s)\n' "$1" "$_elapsed" \
    "${TIMING_FILE#"$REPO_ROOT"/}"
  if [ -s "$TIMING_FILE" ]; then
    printf 'slowest suites:\n'
    sort -t"$(printf '\t')" -k2,2nr "$TIMING_FILE" | head -5 |
      while IFS="$(printf '\t')" read -r _file _ms _status; do
        printf '  %6s s  %s\n' "$((_ms / 1000))" "$_file"
      done
  fi
  if [ "$_elapsed" -ge "$BUDGET_WARN_SECONDS" ]; then
    printf 'warning: %s took %s s, close to the 15 minute job limit: split it or shard it\n' \
      "$1" "$_elapsed" >&2
  fi
}

# `--shard 1/2` keeps one slice of the sorted test list. The slice is positional
# so two jobs with different cache states still run the same files.
shard_keeps() {
  # $1 index (1-based), $2 total shards, $3 wanted shard
  [ $(( ($1 - 1) % $2 + 1 )) -eq "$3" ]
}

nim_check() {
  nim check $CHECK_FLAGS --nimcache:"$NIMCACHE_CHECK" "$@"
}

nim_build() {
  nim c $CHECK_FLAGS $BUILD_FLAGS --nimcache:"$NIMCACHE_BUILD" "$@"
}

test_binary() {
  _file=$1
  _name=$(printf '%s' "$_file" | sed "s|$REPO_ROOT/||" | tr '/.' '__')
  mkdir -p "$NIMCACHE_BUILD/bin"
  printf '%s\n' "$NIMCACHE_BUILD/bin/$_name"
}

# --- machine-readable results (QA-11) ----------------------------------------
#
# A red job that leaves only a scrolling log behind cannot be triaged without a
# rerun. Every runner records one row per suite and writes a JUnit file at the
# end, so CI can upload a report that names the failing file instead of making
# a reviewer search the console output.
JUNIT_DIR=""
JUNIT_FINISHED=0

junit_begin() {
  JUNIT_DIR="$REPO_ROOT/.cache/$WORKTREE/junit"
  mkdir -p "$JUNIT_DIR"
  : >"$JUNIT_DIR/results.tsv"
  JUNIT_FINISHED=0
}

junit_record() {
  # $1 suite path, $2 exit status (0 passed, 77 skipped, anything else failed)
  [ -n "$JUNIT_DIR" ] || return 0
  printf '%s\t%s\n' "$1" "$2" >>"$JUNIT_DIR/results.tsv"
}

junit_finish() {
  [ -n "$JUNIT_DIR" ] || return 0
  [ "$JUNIT_FINISHED" = "0" ] || return 0
  JUNIT_FINISHED=1
  [ -f "$JUNIT_DIR/results.tsv" ] || : >"$JUNIT_DIR/results.tsv"
  awk -F"$(printf '\t')" '
    {
      total++
      if ($2 == 77) skipped++
      else if ($2 != 0) failures++
    }
    END {
      printf "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
      printf "<testsuites tests=\"%d\" failures=\"%d\" skipped=\"%d\">\n", total, failures, skipped
      printf "  <testsuite name=\"nim\" tests=\"%d\" failures=\"%d\" skipped=\"%d\">\n", total, failures, skipped
    }
  ' "$JUNIT_DIR/results.tsv" >"$JUNIT_DIR/junit.xml"
  while IFS="$(printf '\t')" read -r _suite _code; do
    [ -n "$_suite" ] || continue
    _name=$(printf '%s' "$_suite" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' \
      -e 's/>/\&gt;/g' -e 's/"/\&quot;/g')
    if [ "$_code" = "0" ]; then
      printf '    <testcase name="%s"/>\n' "$_name" >>"$JUNIT_DIR/junit.xml"
    elif [ "$_code" = "77" ]; then
      printf '    <testcase name="%s"><skipped/></testcase>\n' "$_name" \
        >>"$JUNIT_DIR/junit.xml"
    else
      printf '    <testcase name="%s"><failure message="exit %s"/></testcase>\n' \
        "$_name" "$_code" >>"$JUNIT_DIR/junit.xml"
    fi
  done <"$JUNIT_DIR/results.tsv"
  printf '  </testsuite>\n</testsuites>\n' >>"$JUNIT_DIR/junit.xml"
}

SKIP_COUNT=0
SKIP_FILES=""

record_skip() {
  _rel=${1#"$REPO_ROOT"/}
  SKIP_COUNT=$((SKIP_COUNT + 1))
  SKIP_FILES="$SKIP_FILES $_rel"
  printf 'SKIP %s\n' "$_rel" >&2
}

handle_suite_status() {
  # Exit code 77 is the reserved "skipped" status. It is reported and counted,
  # never mistaken for a pass. Any other non-zero status fails the gate, and is
  # also written to a machine-readable failure list so a later report does not
  # have to re-parse console output (QA-13).
  case "$1" in
    0) ;;
    77) record_skip "$2" ;;
    *)
      mkdir -p "$REPO_ROOT/.cache/$WORKTREE"
      printf 'FAIL\t%s\t%s\n' "$2" "$1" \
        >>"$REPO_ROOT/.cache/$WORKTREE/failures.tsv"
      return "$1"
      ;;
  esac
}

check_skips() {
  _allow="$REPO_ROOT/task.d/skip-allowlist.txt"
  _today=$(date -u +%F)
  for _f in $SKIP_FILES; do
    _entry=$(awk -F'\t' -v p="$_f" '$1==p{print $0; exit}' "$_allow" 2>/dev/null || true)
    [ -n "$_entry" ] ||
      fail "undocumented skip: $_f (add it to task.d/skip-allowlist.txt with owner and expiry)"
    _exp=$(printf '%s\n' "$_entry" | cut -f3)
    if [ "$_exp" \< "$_today" ]; then
      fail "skip expired: $_f (expired $_exp)"
    fi
  done
  printf 'skips: %s skipped\n' "${SKIP_COUNT:-0}"
}

nim_run() {
  _file=$1
  shift
  _bin=$(test_binary "$_file")
  nim c $CHECK_FLAGS --nimcache:"$NIMCACHE_BUILD" -o:"$_bin" "$_file" >/dev/null
  # `_suite_status`, not `_status`: a caller that records the result in `_status`
  # would otherwise read this function's skip code (77) as its own.
  _suite_status=0
  "$_bin" "$@" || _suite_status=$?
  handle_suite_status "$_suite_status" "$_file"
}

nim_run_check() {
  _file=$1
  shift
  _bin=$(test_binary "$_file")
  nim c $CHECK_FLAGS --nimcache:"$NIMCACHE_CHECK" -o:"$_bin" "$_file" >/dev/null
  _suite_status=0
  "$_bin" "$@" || _suite_status=$?
  handle_suite_status "$_suite_status" "$_file"
}

nim_compile_check() {
  # Compile a suite without running it, so `ci` can keep the compile-only
  # signal while `test` executes the same file once.
  _file=$1
  shift
  nim c $CHECK_FLAGS --nimcache:"$NIMCACHE_CHECK" \
    -o:"$(test_binary "$_file")" "$_file" "$@"
}

list_test_files() {
  # Unit tests always run. Integration tests only when INTEGRATION=1.
  find "$REPO_ROOT/apps" "$REPO_ROOT/modules" "$REPO_ROOT/shared" "$REPO_ROOT/tools" \
    -name '*_test.nim' -type f 2>/dev/null | sort | while IFS= read -r file; do
      case "$file" in
        */tests/integration/*)
          [ "${INTEGRATION:-0}" = "1" ] && printf '%s\n' "$file"
          ;;
        *)
          printf '%s\n' "$file"
          ;;
      esac
    done
}

api_entrypoint() {
  printf '%s\n' "$REPO_ROOT/apps/api/src/main.nim"
}

require_test_dsn() {
  # The suites mutate rows they do not fully own, so both an empty DSN and a
  # name without "test" are refused before the first suite starts.
  # `ALLOW_SHARED_DB=1` is the deliberate opt-out.
  if [ "${ALLOW_SHARED_DB:-0}" = "1" ]; then
    return 0
  fi
  [ -n "${MAJADU_PG_DSN:-}" ] ||
    fail "MAJADU_PG_DSN is empty: run ./task dev-db, then export MAJADU_PG_DSN=postgresql://\$USER@127.0.0.1:5432/bm2_test (set ALLOW_SHARED_DB=1 to override)"
  _name=${MAJADU_PG_DSN%%\?*}
  _name=${_name##*/}
  case "$_name" in
    *test*) ;;
    *)
      fail "refusing database '$_name' from MAJADU_PG_DSN: the name must contain 'test' (set ALLOW_SHARED_DB=1 to override)"
      ;;
  esac
}

# --- one database per test file (QA-06) --------------------------------------
#
# A suite runs as its own process, so a transaction that rolls back at the end
# cannot span two files. The runner therefore hands every file a database of its
# own, copied from a seed database that `bm2_template` plus `db/migrations` and
# `db/seeds` built once for the run. `MAJADU_PG_DSN` names the database the
# operator prepared, and is never written: only its credentials, host, port and
# name are reused, so a suite can no longer see the rows another suite left.

dsn_database() {
  # The database a URI DSN names, without the query string.
  _path=${1%%\?*}
  printf '%s\n' "${_path##*/}"
}

dsn_with_database() {
  # The same credentials, host, port and options, another database. URI form
  # only: a keyword/value DSN has no single path to replace, and a wrong rewrite
  # would point a suite at the database it must not write.
  case "$1" in
    *"://"*/*) ;;
    *) fail "MAJADU_PG_DSN must be a URI (postgresql://user@host:port/db): $1" ;;
  esac
  printf '%s\n' "$1" | sed "s#^\([^?]*/\)[^/?]*#\1$2#"
}

pg_admin_dsn() {
  # The database that may create and drop. `MAJADU_PG_ADMIN_DSN` wins because a
  # role that owns an application database often cannot connect to `postgres`.
  if [ -n "${MAJADU_PG_ADMIN_DSN:-}" ]; then
    printf '%s\n' "$MAJADU_PG_ADMIN_DSN"
  else
    dsn_with_database "$1" postgres
  fi
}

ensure_dbtools() {
  # The migration runner a seed database needs. `nim c` is incremental, so a
  # warm cache costs about a second per run.
  _bin="$NIMCACHE_BUILD/bin/dbtools"
  nim_build -o:"$_bin" "$REPO_ROOT/tools/dbtools/main.nim" >/dev/null
  printf '%s\n' "$_bin"
}

require_database_name() {
  # PostgreSQL truncates an identifier past 63 bytes, and a truncated name is a
  # database this harness can no longer drop.
  case "$1" in
    "") fail "$2: database name is empty" ;;
    *[!a-z0-9_]*) fail "$2: '$1' is not a lowercase database name" ;;
  esac
  if [ "${#1}" -gt 50 ]; then
    fail "$2: '$1' is longer than 50 characters"
  fi
}

admin_sql() {
  # Run one statement against the maintenance database. The output is captured
  # because `drop database if exists` writes a NOTICE when the database is
  # already gone, and a first run would print one per file; a real failure is
  # replayed on stderr and returned.
  _out=$(psql -v ON_ERROR_STOP=1 -q -d "$(pg_admin_dsn "${MAJADU_PG_DSN:-}")" \
    "$@" 2>&1) || {
    printf '%s\n' "$_out" >&2
    return 1
  }
  return 0
}

have_role() {
  [ "$(psql -v ON_ERROR_STOP=1 -At -d "$(pg_admin_dsn "${MAJADU_PG_DSN:-}")" \
    -c "select 1 from pg_roles where rolname = '$1'")" = "1" ]
}

owning_role_clause() {
  # A cluster that never ran `./task dev-db` has no bm2_owner, and the database
  # still has to be creatable by the role the caller is using.
  if have_role bm2_owner; then
    printf ' owner bm2_owner'
  fi
}

grant_connect() {
  for _role in bm2_app bm2_etl; do
    if have_role "$_role"; then
      admin_sql -c "grant connect on database $1 to $_role" ||
        fail "cannot grant connect on $1 to $_role"
    fi
  done
}

free_name() {
  # Drop the database so the next statement can create it.
  admin_sql -c "drop database if exists $1 with (force)" || fail "cannot drop $1"
}

database_clone() {
  # $1 source, $2 target. `create database ... template` copies the files, not
  # the database ACL, so the application roles get their CONNECT back explicitly.
  require_database_name "$1" "source"
  require_database_name "$2" "target"
  free_name "$2"
  _owner=$(owning_role_clause)
  _out=""
  if ! _out=$(psql -v ON_ERROR_STOP=1 -q -d "$(pg_admin_dsn "${MAJADU_PG_DSN:-}")" \
    -c "create database $2 template $1$_owner" 2>&1); then
    case "$_out" in
      *"is being accessed by other users"*)
        fail "cannot copy $1: it has an open session; close it, or run with WORKERS=N to use a worker database"
        ;;
      *)
        fail "cannot copy $1 to $2: $_out"
        ;;
    esac
  fi
  grant_connect "$2"
}

database_drop() {
  # A drop that fails at the end of a run is a warning, not a reason to turn a
  # green run red: the next `fresh` drops the same name again.
  for _db in "$@"; do
    require_database_name "$_db" "database"
    if ! admin_sql -c "drop database if exists $_db with (force)"; then
      printf 'warning: could not drop %s\n' "$_db" >&2
    fi
  done
  return 0
}

worker_database() {
  # $1 base database name, $2 worker number. The seed is rebuilt from
  # bm2_template every run, so a new migration lands here without a manual step,
  # and the live database is then a copy of it.
  require_database_name "$1" "base database"
  case "$2" in
    ""|0|*[!0-9]*) fail "worker number must be a positive integer, got '$2'" ;;
  esac
  database_seed "$1_$2_seed"
  database_clone "$1_$2_seed" "$1_$2"
}

# --- per-file database isolation (QA-06) -----------------------------------
#
# A suite that cleans up after itself still depends on the order its neighbours
# ran in: the shared database hid that, and it made two runs of one file unable
# to overlap. Every script that runs suites one file at a time calls these two:
# `isolation_begin` builds one seed from bm2_template, `isolation_apply` gives
# the next file a fresh copy of it, and the exit trap drops both.
#
# `ISOLATION=0` restores the shared database; `ALLOW_SHARED_DB=1` implies it,
# because that flag is the caller vouching for the database it named. `test.sh`
# keeps its own variant: it also shards across worker databases and records the
# per-file verdicts, which no other target needs.

ISOLATION_ACTIVE=0
ISOLATION_BASE_DSN=""
ISOLATION_SEED=""
ISOLATION_LIVE=""
ISOLATION_DROPS=""

isolation_enabled() {
  case "${ISOLATION:-}" in
    0) return 1 ;;
    1) return 0 ;;
    "")
      if [ "${ALLOW_SHARED_DB:-0}" = "1" ]; then return 1; fi
      return 0
      ;;
    *) fail "ISOLATION must be 0 or 1, got '$ISOLATION'" ;;
  esac
}

isolation_begin() {
  # $1 the target's name, for the message. Requires MAJADU_PG_DSN.
  isolation_enabled || return 0
  [ -n "${MAJADU_PG_DSN:-}" ] || fail "$1 runs database suites and needs MAJADU_PG_DSN"
  require_cmd psql
  ISOLATION_ACTIVE=1
  ISOLATION_BASE_DSN=$MAJADU_PG_DSN
  _base=$(dsn_database "$MAJADU_PG_DSN")
  ISOLATION_SEED="${_base}_seed_$$"
  ISOLATION_LIVE="${_base}_iso_$$"
  ISOLATION_DROPS="$ISOLATION_SEED $ISOLATION_LIVE"
  database_seed "$ISOLATION_SEED" || fail "cannot build a database seed"
  trap isolation_finish EXIT INT TERM
  printf '%s: one fresh database per file (%s from bm2_template; ISOLATION=0 to share %s)\n' \
    "$1" "$ISOLATION_SEED" "$_base"
}

isolation_apply() {
  # $1 the file about to run, for the failure message.
  [ "$ISOLATION_ACTIVE" = "1" ] || return 0
  MAJADU_PG_DSN=$ISOLATION_BASE_DSN
  database_clone "$ISOLATION_SEED" "$ISOLATION_LIVE" >/dev/null ||
    fail "cannot reset $ISOLATION_LIVE for $1"
  MAJADU_PG_DSN=$(dsn_with_database "$ISOLATION_BASE_DSN" "$ISOLATION_LIVE")
  export MAJADU_PG_DSN
}

isolation_finish() {
  [ "$ISOLATION_ACTIVE" = "1" ] || return 0
  ISOLATION_ACTIVE=0
  if [ "${KEEP_TEST_DB:-0}" = "1" ]; then
    printf 'isolation: kept %s\n' "$ISOLATION_DROPS"
    return 0
  fi
  _keep=$MAJADU_PG_DSN
  MAJADU_PG_DSN=$ISOLATION_BASE_DSN
  database_drop $ISOLATION_DROPS >/dev/null 2>&1 || true
  MAJADU_PG_DSN=$_keep
  return 0
}

database_seed() {
  # $1 seed database name. Built from bm2_template: role grants, migrations and
  # seeds. bm2_template is bare by design, so this is the one place the
  # application schema reaches a test database, and it runs once per worker per
  # run rather than once per file.
  require_database_name "$1" "seed"
  [ -n "${MAJADU_PG_DSN:-}" ] ||
    fail "MAJADU_PG_DSN is required to build a database seed"
  psql -v ON_ERROR_STOP=1 -At -d "$(pg_admin_dsn "$MAJADU_PG_DSN")" \
    -c "select 1 from pg_database where datname = 'bm2_template'" |
    grep -qx 1 || fail "bm2_template does not exist: run ./task dev-db"
  _tools=$(ensure_dbtools)
  free_name "$1"
  _owner=$(owning_role_clause)
  admin_sql -c "create database $1 template bm2_template$_owner" ||
    fail "cannot create seed $1"
  grant_connect "$1"
  _seed_dsn=$(dsn_with_database "$MAJADU_PG_DSN" "$1")
  MAJADU_PG_DSN="$_seed_dsn" "$_tools" migrate --dir "$REPO_ROOT/db/migrations" >/dev/null
  MAJADU_PG_DSN="$_seed_dsn" "$_tools" seed --dir "$REPO_ROOT/db/seeds" >/dev/null
}
