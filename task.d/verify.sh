#!/bin/sh
. "$(dirname "$0")/lib.sh"

[ "$#" -ge 1 ] || fail "usage: ./task verify <module|api>"
module=$1

# Suites live beside their module, both directly under tests/ and in a nested
# tests/integration/ (for example platform/config/tests/integration), so a
# module search starts at its root and goes all the way down.
case "$module" in
  api)
    tests_dir="$REPO_ROOT/apps/api/tests"
    ;;
  *)
    tests_dir="$REPO_ROOT/modules/$module"
    [ -d "$tests_dir/tests" ] || fail "no tests directory for module: $module"
    ;;
esac

[ -d "$tests_dir" ] || fail "no tests directory for module: $module"

# A suite that cannot run must never report success, so refuse to start at all
# unless the database the suites need is actually available. The search is
# recursive, so a nested integration directory is not skipped here either.
if [ -z "${MAJADU_PG_DSN:-}" ]; then
  if [ "${INTEGRATION:-0}" = "1" ]; then
    fail "INTEGRATION=1 needs MAJADU_PG_DSN to run the $module suites"
  fi
  if [ -n "$(find "$tests_dir" -path '*/integration/*' -name '*_test.nim' -type f)" ]; then
    fail "MAJADU_PG_DSN is required for integration tests in $module"
  fi
fi

for file in $(find "$tests_dir" -name '*_test.nim' -type f | sort); do
  nim_run "$file"
done

printf 'verify: %s ok\n' "$module"
