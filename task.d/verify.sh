#!/bin/sh
. "$(dirname "$0")/lib.sh"

[ "$#" -ge 1 ] || fail "usage: ./task verify <module|api>"
module=$1

case "$module" in
  api) tests_dir="$REPO_ROOT/apps/api/tests" ;;
  *) tests_dir="$REPO_ROOT/modules/$module/tests" ;;
esac

[ -d "$tests_dir" ] || fail "no tests directory for module: $module"

if [ -d "$tests_dir/integration" ] && [ -z "${MAJADU_PG_DSN:-}" ]; then
  fail "MAJADU_PG_DSN is required for integration tests in $module"
fi

for file in $(find "$tests_dir" -name '*_test.nim' -type f | sort); do
  nim_run "$file"
done

printf 'verify: %s ok\n' "$module"
