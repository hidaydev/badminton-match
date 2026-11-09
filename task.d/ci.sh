#!/bin/sh
. "$(dirname "$0")/lib.sh"

# `test` runs every suite, unit ones included, so `check` only compiles them
# here. Running both would execute the unit suites twice in one job.
sh "$REPO_ROOT/task.d/check.sh" --no-run
sh "$REPO_ROOT/task.d/build.sh"
sh "$REPO_ROOT/task.d/test.sh" --timing

if [ -f "$REPO_ROOT/task.d/contract-check.sh" ]; then
  sh "$REPO_ROOT/task.d/contract-check.sh"
fi

# OPS-25: the mechanical docs claims and the release order are part of the
# gate, so a sentence that contradicts the configuration fails here instead of
# on the next incident.
sh "$REPO_ROOT/task.d/docs-check.sh"

printf 'ci: ok\n'
