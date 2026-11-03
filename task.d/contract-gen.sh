#!/bin/sh
. "$(dirname "$0")/lib.sh"

require_cmd nim

bin="$REPO_ROOT/.cache/$WORKTREE/bin/contract-gen"
mkdir -p "$(dirname "$bin")"

cd "$REPO_ROOT"
nim c $CHECK_FLAGS --nimcache:"$NIMCACHE_CHECK" -o:"$bin" tools/contract-gen/gen.nim
exec "$bin" "$@"
