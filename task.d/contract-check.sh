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

# SEC-10: the fingerprint proves the generated routes match the specs; it says
# nothing about the table the request path reads. Every declared operation needs
# a matrix key and an explicit rule in route_access.nim, or it silently inherits
# the table's fallback class.
sh "$REPO_ROOT/task.d/contract-keys.sh"
