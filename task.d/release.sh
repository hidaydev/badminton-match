#!/bin/sh
# Prepare a release: derive the next SemVer from Conventional Commits.
# Dry run by default; --apply writes VERSION and CHANGELOG.md. The tool never
# tags, commits or pushes - it prints those commands for the operator.
. "$(dirname "$0")/lib.sh"

require_cmd nim
require_cmd git

# QA-04: the tagged commit must be the tree the gate measured. A release branch
# that diverged from main carries a merge at tag time that no CI run covered,
# so it cannot be prepared here. The guard is the operator entrypoint; the
# library tool stays usable on a scratch repository in its own tests.
main_ref=""
for ref in main origin/main; do
  if git -C "$REPO_ROOT" rev-parse --verify -q "$ref" >/dev/null 2>&1; then
    main_ref=$ref
    break
  fi
done
if [ -z "$main_ref" ]; then
  printf 'release: warning: no main or origin/main ref; the tree cannot be proven to contain main\n' >&2
elif ! git -C "$REPO_ROOT" merge-base --is-ancestor "$main_ref" HEAD; then
  fail "release: HEAD does not contain $main_ref; merge $main_ref, run the full gate on the merge and tag that commit (QA-04)"
fi

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
