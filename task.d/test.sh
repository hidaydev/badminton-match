#!/bin/sh
. "$(dirname "$0")/lib.sh"

require_cmd nim

# The suites mutate rows they do not fully own and leave the shared database
# between cases, so a connection whose name does not say "test" is refused
# before the first suite starts. `ALLOW_SHARED_DB=1` is the deliberate opt-out.
if [ -n "${MAJADU_PG_DSN:-}" ]; then
  _name=${MAJADU_PG_DSN%%\?*}
  _name=${_name##*/}
  case "$_name" in
    *test*) ;;
    *)
      [ "${ALLOW_SHARED_DB:-0}" = "1" ] ||
        fail "refusing database '$_name' from MAJADU_PG_DSN: the name must contain 'test' (set ALLOW_SHARED_DB=1 to override)"
      ;;
  esac
fi

INTEGRATION=1
export INTEGRATION

for file in $(list_test_files); do
  nim_run "$file"
done

printf 'test: ok\n'
