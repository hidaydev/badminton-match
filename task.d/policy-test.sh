#!/bin/sh
# The policy set, exercised by the suites that only mean something under it.
#
#   MAJADU_PG_DSN=postgresql://.../bm2_policy_test ./task policy-test
#
# Every other suite runs on a DSN whose role bypasses row security: the
# developer's own role locally, `postgres` in CI. The owner bypasses because 0061
# enables row security and never forces it, so a route that lost its tenant
# scoping answers 200 with the wrong rows and every assertion on that DSN still
# passes. These files are the ones that assert against the policy set itself, and
# every one of them either switches to `bm2_app` or reads the catalogue:
#
#   apps/api/tests/integration/policy_coverage_test.nim      catalogue: policies exist and are shaped
#   apps/api/tests/integration/rls_isolation_test.nim        policies bind for bm2_app, with and without a GUC
#   apps/api/tests/integration/tenant_scope_guc_test.nim     the three pre-context reads as bm2_app
#   apps/api/tests/integration/tenant_scope_route_test.nim   the same three through the real routes as bm2_app
#   apps/api/tests/integration/policy_login_audit_test.nim   a login grant outside the last community by slug
#   apps/api/tests/integration/policy_definer_bytea_test.nim the three definer reads, resolved by real bytes
#   tools/ranksnapshot/tests/integration/snapshot_test.nim   the snapshot write as bm2_app
#
# The database this runs on is built here, from bm2_template plus db/migrations,
# so it always carries 0061. The check below refuses to run if it does not: a
# green run on a policy-free database is exactly the lie `policiesOn` used to
# tell when it was computed and never read.
set -eu
. "$(dirname "$0")/lib.sh"

require_cmd nim
require_cmd psql
require_test_dsn

files="
apps/api/tests/integration/policy_coverage_test.nim
apps/api/tests/integration/rls_isolation_test.nim
apps/api/tests/integration/tenant_scope_guc_test.nim
apps/api/tests/integration/tenant_scope_route_test.nim
apps/api/tests/integration/policy_login_audit_test.nim
apps/api/tests/integration/policy_definer_bytea_test.nim
tools/ranksnapshot/tests/integration/snapshot_test.nim
"

for file in $files; do
  [ -f "$REPO_ROOT/$file" ] || fail "policy-test: missing $file"
done

isolation_begin policy-test

# `isolation_begin` installs its own EXIT trap, and a second `trap ... EXIT`
# replaces it instead of adding to it: the seed and the per-file copy would then
# be left behind on every run. One handler does both, the way `test.sh` does it.
finish() {
  junit_finish
  isolation_finish
}
trap finish EXIT INT TERM
junit_begin

# The precondition, checked before a single suite runs. `bm2_template` is bare,
# so the only way the policy set reaches this database is a migration, and a
# database past 0060 that somehow lost it is a defect this target must name
# rather than pass through.
#
# The DSN, not the bare name: `-d <name>` connects over the unix socket, which
# exists on a developer machine and does not exist in CI, and a connection error
# then reads as "the migrations never reached 0061". The two cases are kept
# apart on purpose: only a count that really came back 0 may claim no policies.
seed_dsn=$(dsn_with_database "$ISOLATION_BASE_DSN" "$ISOLATION_SEED")
policies=$(psql -v ON_ERROR_STOP=1 -At -d "$seed_dsn" -c \
  "select count(*) from pg_policies where schemaname not in ('pg_catalog','information_schema')" 2>&1) ||
  fail "policy-test: cannot connect to $ISOLATION_SEED to read pg_policies: $policies"
case "$policies" in
  ''|*[!0-9]*) fail "policy-test: pg_policies returned '$policies'" ;;
  0) fail "policy-test: $ISOLATION_SEED has no policies; db/migrations must reach 0061 (0061_rls_tenant_policies.sql)" ;;
esac
printf 'policy-test: %s policies in %s\n' "$policies" "$ISOLATION_SEED"

INTEGRATION=1
export INTEGRATION

for file in $files; do
  isolation_apply "$file"
  _start=$(now_ms)
  run_status=0
  nim_run "$REPO_ROOT/$file" || run_status=$?
  junit_record "${file#"$REPO_ROOT"/}" "$run_status" "$(( $(now_ms) - _start ))"
done

printf 'policy-test: %s suite(s) ok\n' "$(printf '%s\n' $files | wc -l | tr -d ' ')"
