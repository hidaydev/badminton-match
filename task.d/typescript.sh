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

# Types, lint, the source half of the touch gate, docs and the unit suites. No
# build: this is the cheap pass, so a type error fails before anything compiles.
pnpm --dir "$REPO_ROOT" check:web

# MAJ-03: the touch gate's second half reads the built stylesheet, so the
# artifact has to exist before the assertion. It is the rule `hit44` was missing
# on 2026-11-26: 111 tokens in source, no `.hit44` rule in the build, and a
# green gate because the check matched spelling. Measured at 3debec10: web
# 6.2s, scoreboard 2.7s.
pnpm --dir "$REPO_ROOT" build:web
pnpm --dir "$REPO_ROOT" build:scoreboard
# A gate that cannot fail is not a gate. The negative case runs on a copy of the
# real artifact, so an edit that makes the gate always pass fails here instead
# of shipping.
node "$REPO_ROOT/apps/web/scripts/touch-gate-selftest.mjs"
pnpm --dir "$REPO_ROOT" --filter badminton-pair-tmp run check:touch-artifact
