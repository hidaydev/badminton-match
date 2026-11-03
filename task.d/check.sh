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

printf 'check: ok\n'
