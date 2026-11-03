#!/bin/sh
# Contract gate: fails when the specs, generated route skeletons, or generated
# TypeScript client drift from packages/contracts/openapi/CONTRACT.sha256.
. "$(dirname "$0")/lib.sh"

require_cmd nim

bin="$REPO_ROOT/.cache/$WORKTREE/bin/contract-check"
mkdir -p "$(dirname "$bin")"

# Report per-entry drift first; the generator check below is the byte-exact
# backstop for every generated artifact.
cd "$REPO_ROOT"
nim c $CHECK_FLAGS --nimcache:"$NIMCACHE_CHECK" -o:"$bin" tools/contract-gen/check.nim
"$bin" "$@"

sh "$REPO_ROOT/task.d/contract-gen.sh" --check
