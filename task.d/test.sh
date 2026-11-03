#!/bin/sh
. "$(dirname "$0")/lib.sh"

require_cmd nim

INTEGRATION=1
export INTEGRATION

for file in $(list_test_files); do
  nim_run "$file"
done

printf 'test: ok\n'
