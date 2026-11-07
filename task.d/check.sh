#!/bin/sh
# Fast gate: no database, no release build.
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

nim_check "$(api_entrypoint)"

for file in $(list_test_files); do
  if [ "$run_suites" = "1" ]; then
    nim_run_check "$file" >/dev/null
  else
    nim_compile_check "$file" >/dev/null
  fi
done

if [ -f "$REPO_ROOT/tools/archcheck/main.nim" ]; then
  nim_run_check "$REPO_ROOT/tools/archcheck/main.nim"
fi

# `check` intentionally runs no database suite, so say whether the unit suites
# ran instead of letting `ok` imply more than that happened.
if [ "$run_suites" = "1" ]; then
  printf 'check: ok (unit suites only; database suites need ./task test)\n'
else
  printf 'check: ok (unit suites compiled, not run; ./task test runs them)\n'
fi
