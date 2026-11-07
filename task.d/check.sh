#!/bin/sh
# Fast gate: no database, no release build.
. "$(dirname "$0")/lib.sh"

require_cmd nim

nim_check "$(api_entrypoint)"

for file in $(list_test_files); do
  nim_run_check "$file" >/dev/null
done

if [ -f "$REPO_ROOT/tools/archcheck/main.nim" ]; then
  nim_run_check "$REPO_ROOT/tools/archcheck/main.nim"
fi

# `check` compiles everything but intentionally runs no database suite, so say
# so instead of letting `ok` imply those suites were executed.
printf 'check: ok (unit suites only; database suites need ./task test)\n'
