#!/bin/sh
# Issue, list and revoke bearer tokens for CLI/ops access.
. "$(dirname "$0")/lib.sh"

: "${MAJADU_PG_DSN:?MAJADU_PG_DSN is required}"

nim_build -o:"$NIMCACHE_BUILD/bin/opstoken" tools/opstoken/main.nim

MAJADU_PG_DSN="$MAJADU_PG_DSN" "$NIMCACHE_BUILD/bin/opstoken" "$@"
