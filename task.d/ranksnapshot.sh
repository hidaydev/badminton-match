#!/bin/sh
# Write today's ranking snapshot for every community.
. "$(dirname "$0")/lib.sh"

: "${MAJADU_PG_DSN:?MAJADU_PG_DSN is required}"

nim_build -o:"$NIMCACHE_BUILD/bin/ranksnapshot" tools/ranksnapshot/main.nim

MAJADU_PG_DSN="$MAJADU_PG_DSN" "$NIMCACHE_BUILD/bin/ranksnapshot" "$@"
