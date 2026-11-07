#!/bin/sh
. "$(dirname "$0")/lib.sh"

require_cmd nim

# The suites fall back to a local database when the DSN is unset, and they
# mutate rows they do not fully own, so both an empty DSN and a name without
# "test" are refused before the first suite starts. `ALLOW_SHARED_DB=1` is the
# deliberate opt-out.
if [ "${ALLOW_SHARED_DB:-0}" != "1" ]; then
  [ -n "${MAJADU_PG_DSN:-}" ] ||
    fail "MAJADU_PG_DSN is empty: its database name must contain 'test' (set ALLOW_SHARED_DB=1 to override)"
  _name=${MAJADU_PG_DSN%%\?*}
  _name=${_name##*/}
  case "$_name" in
    *test*) ;;
    *)
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
