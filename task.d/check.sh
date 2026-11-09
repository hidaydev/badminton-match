#!/bin/sh
# Fast gate: no release build, no database. QA-25.
. "$(dirname "$0")/lib.sh"

# `--no-run` compiles the unit suites without executing them. `ci` passes it
# because `test` runs the same files once, together with the integration set.
run_suites=1
if [ "$#" -gt 1 ]; then
  fail "usage: ./task check [--no-run]"
fi
case "${1:-}" in
  "") ;;
  --no-run) run_suites=0 ;;
  *) fail "usage: ./task check [--no-run]" ;;
esac

require_cmd nim

# QA-25: `check` is the database-free gate. Everything that opens a database or
# starts a server lives under `tests/integration/` and runs from `./task test`,
# so a laptop without Postgres can run this one.
layer_counts

nim_check "$(api_entrypoint)"
sh "$REPO_ROOT/task.d/deadcode.sh"

# QA-11: the JUnit report is written even when the first failing suite stops
# the loop, so a red run leaves a machine-readable result behind.
junit_begin
trap 'junit_finish' EXIT

if [ "$run_suites" = "1" ]; then
  timing_begin check
fi
for file in $(list_test_files); do
  if [ "$run_suites" = "1" ]; then
    _start=$(now_ms)
    _code=0
    # The suite output is captured instead of discarded: a failing suite has to
    # say why in the job log. A pass stays quiet.
    _log=$(mktemp "${TMPDIR:-/tmp}/majadu-check.XXXXXX")
    nim_run_check "$file" >"$_log" 2>&1 || _code=$?
    _elapsed=$(( $(now_ms) - _start ))
    junit_record "${file#"$REPO_ROOT"/}" "$_code" "$_elapsed"
    timing_add "${file#"$REPO_ROOT"/}" "$_elapsed" "$_code"
    if [ "$_code" -ne 0 ]; then
      printf 'check: %s failed with exit %s\n' "${file#"$REPO_ROOT"/}" \
        "$_code" >&2
      cat "$_log" >&2
      rm -f "$_log"
      exit "$_code"
    fi
    if grep -q '^SKIP ' "$_log" 2>/dev/null; then
      # The capture would otherwise hide the per-suite skip names, which used to
      # reach the log through stderr.
      grep '^SKIP ' "$_log" >&2
    fi
    rm -f "$_log"
  else
    nim_compile_check "$file" >/dev/null
  fi
done

if [ -f "$REPO_ROOT/tools/archcheck/main.nim" ]; then
  _code=0
  nim_run_check "$REPO_ROOT/tools/archcheck/main.nim" || _code=$?
  junit_record "tools/archcheck/main.nim" "$_code"
  [ "$_code" -eq 0 ] || exit "$_code"
fi

# QA-10: the same 12 minute warning `test` and `coverage` print, so the job that
# runs this gate says when it is getting close to the 15 minute contract.
if [ "$run_suites" = "1" ]; then
  timing_summary check
fi

# QA-13: a quarantine without an owner or an expiry is a retry count in
# disguise, so the register is validated on every check. The same pass reads the
# low-coverage manifest: a file under 80 percent needs a dated exception.
sh "$REPO_ROOT/task.d/flakeregister.sh"
sh "$REPO_ROOT/task.d/coverage-debt.sh"

# QA-11: the TypeScript coverage threshold is part of this gate, not only of CI.
# `--no-run` is the compile-only mode `ci` uses before `test`, and the TypeScript
# half is a test run, so it stays out of that pass.
if [ "$run_suites" = "1" ]; then
  sh "$REPO_ROOT/task.d/typescript.sh"
fi

if [ "$run_suites" = "1" ]; then
  check_skips
fi

# `check` runs the unit layer, not the integration set. Say which ones ran
# instead of letting `ok` imply more than that happened.
if [ "$run_suites" = "1" ]; then
  printf 'check: ok (unit suites only; ./task test adds the integration set)\n'
else
  printf 'check: ok (unit suites compiled, not run; ./task test runs them)\n'
fi
