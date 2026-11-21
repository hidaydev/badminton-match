#!/bin/sh
. "$(dirname "$0")/lib.sh"

require_cmd nim

usage() {
  cat <<'EOF'
usage: ./task test [--timing] [--shard I/N] [--reverse] [--order-check]

  --timing        record per-suite wall time in .cache/<worktree>/timing/test.tsv
  --shard I/N     run slice I of N of the sorted suite list (1-based), split by
                  measured cost when task.d/test-costs.tsv exists, else by position
  --reverse       run the list back to front; the next run then names every file
                  whose result depends on the order its neighbours ran in
  --order-check   run the list forward, then back to front, inside this one
                  invocation, and fail the run when a suite changes its result.
                  This is the self-contained form of --reverse: it needs no
                  second run by hand and no report left over from another job
                  (REL-QA-08). Combine it with --shard to fit a shard budget.

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
order_check=0
shard_index=1
shard_total=1
while [ "$#" -gt 0 ]; do
  case "$1" in
    --timing) timing=1 ;;
    --reverse) reverse=1 ;;
    --order-check) order_check=1 ;;
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

# Two orderings in one invocation already covers what --reverse asked for, so
# asking for both is a contradiction rather than a bigger check.
if [ "$reverse" = "1" ] && [ "$order_check" = "1" ]; then
  usage >&2
  fail "--reverse and --order-check both run a second ordering; pass one"
fi

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
# One verdict file per invocation. The old pair (`isolation.tsv` /
# `isolation-reverse.tsv`) existed so two separate jobs could be compared after
# the fact; no workflow ever shared them, so `--order-check` compares the two
# orderings it ran itself instead (REL-QA-08).
report_tsv="$CACHE_DIR/isolation.tsv"

base_dsn=$MAJADU_PG_DSN
base_db=$(dsn_database "$base_dsn")
seed_db=""
live_db=""
drop_on_exit=""
finished=0

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
# An empty list is not a green run: `suites: 0 unit, 0 integration` followed by
# `test: ok` is how a tag ships with no API suite executed.
[ -n "$files" ] ||
  fail "no test suite matched under apps modules shared tools; refusing to report ok"
if [ "$reverse" = "1" ]; then
  files=$(printf '%s\n' "$files" |
    awk '{ line[NR] = $0 } END { for (i = NR; i > 0; i--) print line[i] }')
fi

# BM-03: a cost table turns the positional slice into a cost-aware one; the
# positional path stays the fallback for a checkout without the table.
planned=0
if [ -s "$TEST_COST_FILE" ] && [ "$shard_total" -ge 2 ]; then
  files=$(printf '%s\n' "$files" | shard_plan "$shard_total" "$shard_index")
  planned=1
fi

run_phase() {
  # $1 verdict file (`<rel><TAB><status>` for every suite in this phase),
  # $2 1 to walk the list back to front,
  # $3 1 to stop at the first failure, 0 to record it and carry on.
  #
  # The phase always writes its verdict file, whatever the isolation mode: the
  # comparator in `--order-check` needs both orderings from THIS invocation, and
  # the old code could only compare two files left behind by two separate jobs
  # that no workflow shared (REL-QA-08).
  _phase_tsv=$1
  _phase_reverse=$2
  _phase_stop=$3
  : >"$_phase_tsv"
  _phase_files=$files
  if [ "$_phase_reverse" = "1" ]; then
    _phase_files=$(printf '%s\n' "$_phase_files" |
      awk '{ line[NR] = $0 } END { for (i = NR; i > 0; i--) print line[i] }')
  fi
  # `PHASE_INDEX` / `PHASE_RAN` rather than plain globals: the shard summary
  # below reports the forward phase's counts, and the reversed phase would
  # otherwise overwrite them with an identical-but-unintended pair.
  index=0
  ran=0
  PHASE_INDEX=0
  PHASE_RAN=0
  PHASE_FAILED=0
  PHASE_FAILED_FILE=""
  for file in $_phase_files; do
    index=$((index + 1))
    [ "$planned" = "1" ] || shard_keeps "$index" "$shard_total" "$shard_index" || continue
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
    # Only the first (forward) phase feeds the JUnit report and the timing
    # table: recording the second ordering too would double every row and make
    # the run look twice as long as it was.
    if [ "$_phase_stop" = "1" ]; then
      junit_record "$rel" "$run_status" "$_elapsed"
      if [ "$timing" = "1" ]; then
        timing_add "$rel" "$_elapsed" "$run_status"
      fi
    fi
    printf '%s\t%s\n' "$rel" "$run_status" >>"$_phase_tsv"
  PHASE_INDEX=$index
  PHASE_RAN=$ran
  # The status of the first failure this phase saw, so `--order-check` can tell
  # "broken everywhere" from "broken only in this order".
  if [ "$run_status" -ne 0 ] && [ "$PHASE_FAILED" -eq 0 ]; then
    PHASE_FAILED=$run_status
    PHASE_FAILED_FILE=$rel
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
    # The forward phase stops at the first real failure, exactly as a normal
    # `./task test` does. The reversed phase keeps going: the comparator is what
    # turns a difference into a named list instead of "the first suite that
    # broke in the other order".
    if [ "$run_status" -ne 0 ] && [ "$_phase_stop" = "1" ]; then
      exit "$run_status"
    fi
  done
}

compare_orders() {
  # $1 forward verdict file, $2 reverse verdict file.
  # A suite that passes in one order and fails in the other is leaning on a
  # neighbour: it is the only thing this comparison is for, and it is a gate
  # failure, not a note in a log nothing reads.
  awk -F"$(printf '\t')" -v forward="$1" -v reverse="$2" '
    FNR == NR { pass[$1] = ($2 == 0); next }
    { rev[$1] = ($2 == 0); seen[$1] = 1 }
    END {
      for (file in pass) {
        if (!(file in seen)) continue
        if (pass[file] != rev[file]) {
          state = (pass[file] ? "passed" : "failed") " in the sorted order, " \
            (rev[file] ? "passed" : "failed") " reversed"
          print file "\t" state
          n++
        }
      }
      exit (n > 0 ? 1 : 0)
    }' "$1" "$2"
}

if [ "$order_check" = "1" ]; then
  _forward_tsv="$CACHE_DIR/order-forward.tsv"
  _reverse_tsv="$CACHE_DIR/order-reverse.tsv"
  # Both phases run the whole list. Stopping the forward phase at its first
  # failure would hide the very comparison this flag exists for: a suite that
  # fails forward would never be seen passing in the other order, and the
  # report would name the wrong cause. A failure that shows up in both orders is
  # still reported, one line below the difference check.
  run_phase "$_forward_tsv" 0 0
  _forward_failed=$PHASE_FAILED
  _forward_file=$PHASE_FAILED_FILE
  run_phase "$_reverse_tsv" 1 0
  _reverse_failed=$PHASE_FAILED
  if _changed=$(compare_orders "$_forward_tsv" "$_reverse_tsv"); then
    printf 'isolation: no suite changes its result when the run order is reversed\n'
  else
    printf 'isolation: the run order changes the result for:\n' >&2
    printf '%s\n' "$_changed" |
      while IFS="$(printf '\t')" read -r _file _why; do
        printf '  %s (%s)\n' "$_file" "$_why" >&2
      done
    _named=$(printf '%s\n' "$_changed" | cut -f1 | tr '\n' ' ')
    fail "order dependence: ${_named% } changed result between the sorted and the reversed run"
  fi
  # No order difference, but a suite is broken in both directions: that is an
  # ordinary failure, reported with the file and status the forward run recorded.
  if [ "$_forward_failed" -ne 0 ]; then
    fail "$_forward_file failed (exit $_forward_failed) in both run orders"
  fi
  if [ "$_reverse_failed" -ne 0 ]; then
    # Reached only if the reverse phase broke a suite the forward run passed
    # without the comparator seeing a difference, which would be a bug here.
    fail "the reversed run failed (exit $_reverse_failed) where the sorted run did not"
  fi
else
  # The default path is unchanged: one forward walk, stop at the first failure.
  run_phase "$report_tsv" 0 1
fi

if [ "$shard_total" -gt 1 ]; then
  # A shard that kept nothing is not a passing shard: it proves the slice
  # arithmetic ran off the end of the list, not that the suites passed.
  [ "$PHASE_RAN" -gt 0 ] ||
    fail "shard $shard_index/$shard_total kept no suite; check --shard"
  printf 'test: shard %s/%s ran %s of %s suite(s)\n' "$shard_index" \
    "$shard_total" "$PHASE_RAN" "$PHASE_INDEX"
fi

check_skips

if [ "$timing" = "1" ]; then
  timing_summary test
fi

finish

printf 'test: ok\n'