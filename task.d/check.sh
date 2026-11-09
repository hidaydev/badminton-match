#!/bin/sh
# Fast gate: no release build. Requires a database (D-6).
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

# D-6: `check` runs the database-backed suites, so the database contract is the
# same as `test` when suites actually run. Without a DSN the five security
# suites would silently not run. `--no-run` only compiles them.
if [ "$run_suites" = "1" ]; then
  require_test_dsn
fi

nim_check "$(api_entrypoint)"
sh "$REPO_ROOT/task.d/deadcode.sh"

# QA-11: the JUnit report is written even when the first failing suite stops
# the loop, so a red run leaves a machine-readable result behind.
junit_begin
trap 'junit_finish' EXIT

# QA-06: the database-backed suites get a fresh database per file here too, or
# a suite that no longer resets its rows fails on whatever the last run left.
if [ "$run_suites" = "1" ]; then
  isolation_begin check
  timing_begin check
fi
for file in $(list_test_files); do
  if [ "$run_suites" = "1" ]; then
    isolation_apply "${file#"$REPO_ROOT"/}"
    _start=$(now_ms)
    _code=0
    # The suite output is captured instead of discarded: a failing suite has to
    # say why in the job log. A pass stays quiet.
    _log=$(mktemp "${TMPDIR:-/tmp}/majadu-check.XXXXXX")
    nim_run_check "$file" >"$_log" 2>&1 || _code=$?
    junit_record "${file#"$REPO_ROOT"/}" "$_code"
    timing_add "${file#"$REPO_ROOT"/}" "$(( $(now_ms) - _start ))" "$_code"
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
  junit_record "tools/archcheck/main.nim" 0
  nim_run_check "$REPO_ROOT/tools/archcheck/main.nim"
fi

# QA-10: the same 12 minute warning `test` and `coverage` print, so the job that
# runs this gate says when it is getting close to the 15 minute contract.
if [ "$run_suites" = "1" ]; then
  timing_summary check
fi

# QA-13: a quarantine without an owner or an expiry is a retry count in
# disguise, so the register is validated on every check.
sh "$REPO_ROOT/task.d/flakeregister.sh"

# QA-11: the TypeScript coverage threshold is part of this gate, not only of CI.
# `--no-run` is the compile-only mode `ci` uses before `test`, and the TypeScript
# half is a test run, so it stays out of that pass.
if [ "$run_suites" = "1" ]; then
  sh "$REPO_ROOT/task.d/typescript.sh"
fi

if [ "$run_suites" = "1" ]; then
  check_skips
fi

# `check` runs unit and database-backed suites, not the integration set. Say
# which ones ran instead of letting `ok` imply more than that happened.
if [ "$run_suites" = "1" ]; then
  printf 'check: ok (unit and database-backed suites; ./task test adds the integration set)\n'
else
  printf 'check: ok (unit suites compiled, not run; ./task test runs them)\n'
fi
