#!/bin/sh
# SEC-10: every contract operation must be keyed in the access matrix and
# classified by an explicit rule in route_access.nim. Called by
# `./task contract-check`; run it alone to see the offending operation.
. "$(dirname "$0")/lib.sh"

require_cmd nim

bin="$REPO_ROOT/.cache/$WORKTREE/bin/contract-keys"
mkdir -p "$(dirname "$bin")"

cd "$REPO_ROOT"
nim c $CHECK_FLAGS --nimcache:"$NIMCACHE_CHECK" -o:"$bin" tools/contract-keys/main.nim
exec "$bin" "$@"
