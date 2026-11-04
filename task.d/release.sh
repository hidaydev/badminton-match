#!/bin/sh
# Prepare a release: derive the next SemVer from Conventional Commits.
# Dry run by default; --apply writes VERSION and CHANGELOG.md. The tool never
# tags, commits or pushes - it prints those commands for the operator.
. "$(dirname "$0")/lib.sh"

require_cmd nim
require_cmd git

binary="$NIMCACHE_BUILD/bin/majadu-release"
mkdir -p "$NIMCACHE_BUILD/bin"
nim_build -o:"$binary" "$REPO_ROOT/tools/release/main.nim" >/dev/null

apply=0
for argument in "$@"; do
  if [ "$argument" = "--apply" ]; then
    apply=1
  fi
done

if [ "$apply" -eq 1 ]; then
  exec "$binary" --repo "$REPO_ROOT" "$@"
fi
exec "$binary" --repo "$REPO_ROOT" --dry-run "$@"
