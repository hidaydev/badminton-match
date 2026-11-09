#!/bin/sh
# The TypeScript half of the gate (QA-11). `./task check` calls it because a
# coverage threshold that only CI evaluates is not a gate a developer can run.
#
# Ratchet policy, the same shape as the Nim baseline:
#   * a threshold may only be raised, never lowered;
#   * after a change that raises coverage, raise the thresholds in the
#     package's vitest config in the same commit; the config carries the
#     measured totals and the per-file floors for the behaviour-carrying trees;
#   * a file that drops by more than 0.1 point is a regression, even when the
#     total still passes, and the per-package threshold is not a substitute for
#     reading the report;
#   * the only product exclusion is `apps/web/src/i18n/en.ts` (D-3), and it is
#     written as an explicit path in the web config.
. "$(dirname "$0")/lib.sh"

require_cmd pnpm

if [ ! -d "$REPO_ROOT/node_modules" ]; then
  fail "node_modules is missing: run pnpm install before ./task check"
fi

pnpm --dir "$REPO_ROOT" check:web