#!/bin/sh
. "$(dirname "$0")/lib.sh"

sh "$REPO_ROOT/task.d/check.sh"
sh "$REPO_ROOT/task.d/build.sh"
sh "$REPO_ROOT/task.d/test.sh"

if [ -f "$REPO_ROOT/task.d/contract-check.sh" ]; then
  sh "$REPO_ROOT/task.d/contract-check.sh"
fi

printf 'ci: ok\n'
