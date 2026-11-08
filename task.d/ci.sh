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

printf 'ci: ok\n'
