#!/bin/sh
. "$(dirname "$0")/lib.sh"

require_cmd nim

usage() {
  cat <<'EOF'
usage: ./task test [--timing] [--shard I/N] [--reverse]

  --timing     record per-suite wall time in .cache/<worktree>/timing/test.tsv
  --shard I/N  run slice I of N of the sorted suite list (1-based)
  --reverse    run the list back to front; the next run then names every file
               whose result depends on the order its neighbours ran in

environment:
  WORKERS=N      one worker database per slot, <db>_1 .. <db>_N, each built once
                 from bm2_template and migrated and seeded once; a file takes
                 worker (k - 1) % N + 1, where k is its position among the files
                 this run keeps, so two shards never share rows
  ISOLATION=0    hand every suite the configured database itself, the pre-QA-06
                 behaviour, where a suite has to clean up after itself;
                 ALLOW_SHARED_DB=1 implies it, and ISOLATION=1 overrides that
  KEEP_TEST_DB=1 keep the per-file databases for inspection
EOF
}

timing=0
reverse=0
shard_index=1
shard_total=1
while [ "$#" -gt 0 ]; do
  case "$1" in
    --timing) timing=1 ;;
    --reverse) reverse=1 ;;
    --shard)
      [ "$#" -ge 2 ] || { usage >&2; fail "--shard needs I/N"; }
      shard_index=${2%%/*}
      shard_total=${2##*/}
      case "$shard_index$shard_total" in
        *[!0-9]*|"") usage >&2; fail "--shard needs I/N, got '$2'" ;;
      esac
      [ "$shard_total" -ge 1 ] && [ "$shard_index" -ge 1 ] &&
        [ "$shard_index" -le "$shard_total" ] ||
        { usage >&2; fail "--shard out of range: $2"; }
      shift
      ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; fail "unknown argument: $1" ;;
  esac
  shift
done

require_test_dsn

# QA-11: one JUnit row per suite, so a red run can be downloaded instead of
# re-run. The report is written even when the first failure stops the loop.
junit_begin
trap 'junit_finish' EXIT

isolation=${ISOLATION:-}
if [ -z "$isolation" ]; then
  # The shared-database escape hatch is a promise that the caller vouches for
  # the database it named, so the harness does not assume it may create more.
  # ISOLATION=1 still overrides it explicitly.
  if [ "${ALLOW_SHARED_DB:-0}" = "1" ]; then
    isolation=0
  else
    isolation=1
  fi
fi
case "$isolation" in
  0|1) ;;
  *) usage >&2; fail "ISOLATION must be 0 or 1, got '$isolation'" ;;
esac

workers=0
case "${WORKERS:-}" in
  "") ;;
  *[!0-9]*) usage >&2; fail "WORKERS must be a whole number, got '$WORKERS'" ;;
  *) workers=$WORKERS ;;
esac
slot_count=1
if [ "$workers" -ge 1 ]; then
  slot_count=$workers
else
  workers=0
fi

INTEGRATION=1
export INTEGRATION
layer_counts

CACHE_DIR="$REPO_ROOT/.cache/$WORKTREE"
mkdir -p "$CACHE_DIR"
isolation_tsv="$CACHE_DIR/isolation.tsv"
reverse_tsv="$CACHE_DIR/isolation-reverse.tsv"
if [ "$reverse" = "1" ]; then
  report_tsv=$reverse_tsv
else
  report_tsv=$isolation_tsv
fi

base_dsn=$MAJADU_PG_DSN
base_db=$(dsn_database "$base_dsn")
seed_db=""
live_db=""
drop_on_exit=""
finished=0

reduce_isolation() {
  # One row per file: the last run of that file wins, so two shards that append
  # to the same list still reduce to a single verdict each.
  [ -f "$1" ] || return 0
  awk -F"$(printf '\t')" '{ verdict[$1] = $2 "\t" $3 }
    END { for (file in verdict) print file "\t" verdict[file] }' "$1" >"$1.tmp"
  sort "$1.tmp" >"$1"
  rm -f "$1.tmp"
}

report_isolation() {
  reduce_isolation "$report_tsv"
  [ -f "$isolation_tsv" ] && [ -f "$reverse_tsv" ] || return 0
  # Comparing the two orders is the whole point of --reverse: a file that passes
  # in the sorted order and fails back to front is leaning on a neighbour.
  _changed=$(awk -F"$(printf '\t')" '
    FNR == NR { forward[$1] = $3; next }
    ($1 in forward) && forward[$1] != $3 {
      direction = forward[$1] " in the sorted order, " $3 " reversed"
      print $1 "\t" direction
    }' "$isolation_tsv" "$reverse_tsv")
  if [ -z "$_changed" ]; then
    printf 'isolation: no file changes its result when the run order is reversed\n'
    return 0
  fi
  printf 'isolation: the run order changes the result for:\n'
  printf '%s\n' "$_changed" |
    while IFS="$(printf '\t')" read -r _file _why; do
      printf '  %s (%s)\n' "$_file" "$_why"
    done
}

cleanup_databases() {
  [ -n "$drop_on_exit" ] || return 0
  if [ "${KEEP_TEST_DB:-0}" = "1" ]; then
    printf 'test: kept %s\n' "$drop_on_exit"
    return 0
  fi
  MAJADU_PG_DSN="$base_dsn"
  database_drop $drop_on_exit >/dev/null 2>&1 || true
}

finish() {
  junit_finish
  [ "$finished" = "0" ] || return 0
  finished=1
  if [ "$isolation" = "1" ]; then
    report_isolation || true
  fi
  cleanup_databases || true
  return 0
}

if [ "$isolation" = "1" ]; then
  require_cmd psql
  if [ "$workers" -ge 1 ]; then
    slot=1
    worker_names=""
    while [ "$slot" -le "$slot_count" ]; do
      worker_database "$base_db" "$slot" ||
        fail "cannot build worker database ${base_db}_$slot"
      worker_names="$worker_names ${base_db}_$slot"
      drop_on_exit="$drop_on_exit ${base_db}_$slot ${base_db}_${slot}_seed"
      slot=$((slot + 1))
    done
    printf 'test: %s worker database(s) from bm2_template:%s\n' \
      "$slot_count" "$worker_names"
  else
    seed_db="${base_db}_seed_$$"
    live_db="${base_db}_iso_$$"
    database_seed "$seed_db" || fail "cannot build a database seed"
    drop_on_exit="$seed_db $live_db"
    printf 'test: one fresh database per file (%s built from bm2_template; ISOLATION=0 to share it)\n' \
      "$base_db"
  fi
  trap finish EXIT
fi

if [ "$timing" = "1" ]; then
  timing_begin test
fi

# One clean failure list per run: QA-13 reads it to name what broke without
# re-parsing the console output of a long job.
: >"$CACHE_DIR/failures.tsv"

files=$(list_test_files)
if [ "$reverse" = "1" ]; then
  files=$(printf '%s\n' "$files" |
    awk '{ line[NR] = $0 } END { for (i = NR; i > 0; i--) print line[i] }')
fi

index=0
ran=0
for file in $files; do
  index=$((index + 1))
  shard_keeps "$index" "$shard_total" "$shard_index" || continue
  ran=$((ran + 1))
  rel=${file#"$REPO_ROOT"/}

  database=$base_db
  if [ "$isolation" = "1" ]; then
    if [ "$workers" -ge 1 ]; then
      # The slot follows the position among the files this run keeps, not the
      # position in the full list: a positional shard takes every N-th file, and
      # keying the worker off the full index would send a whole shard to one
      # worker whenever that stride and the worker count share a factor.
      slot=$(( (ran - 1) % slot_count + 1 ))
      database="${base_db}_$slot"
      seed="${base_db}_${slot}_seed"
    else
      database=$live_db
      seed=$seed_db
    fi
    MAJADU_PG_DSN=$base_dsn
    database_clone "$seed" "$database" >/dev/null ||
      fail "cannot reset $database for $rel"
    MAJADU_PG_DSN=$(dsn_with_database "$base_dsn" "$database")
    export MAJADU_PG_DSN
  fi

  _start=$(now_ms)
  _skips_before=$SKIP_COUNT
  run_status=0
  nim_run "$file" || run_status=$?
  _elapsed=$(( $(now_ms) - _start ))
  junit_record "$rel" "$run_status" "$_elapsed"
  if [ "$timing" = "1" ]; then
    timing_add "$rel" "$_elapsed" "$run_status"
  fi

  verdict=PASS
  if [ "$run_status" -ne 0 ]; then
    verdict=FAIL
  elif [ "$SKIP_COUNT" -gt "$_skips_before" ]; then
    verdict=SKIP
  fi
  if [ "$isolation" = "1" ]; then
    printf 'fresh %s  %s  %s\n' "$database" "$verdict" "$rel"
    printf '%s\t%s\t%s\n' "$rel" "$database" "$verdict" >>"$report_tsv"
  fi
  [ "$run_status" -eq 0 ] || exit "$run_status"
done

if [ "$shard_total" -gt 1 ]; then
  printf 'test: shard %s/%s ran %s of %s suite(s)\n' "$shard_index" \
    "$shard_total" "$ran" "$index"
fi

check_skips

if [ "$timing" = "1" ]; then
  timing_summary test
fi

finish

printf 'test: ok\n'