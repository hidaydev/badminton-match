#!/bin/sh
# Ingest approved sessions into rating events and deltas.
. "$(dirname "$0")/lib.sh"

: "${MAJADU_PG_DSN:?MAJADU_PG_DSN is required}"

nim_build -o:"$NIMCACHE_BUILD/bin/ratingingest" tools/ratingingest/main.nim

MAJADU_PG_DSN="$MAJADU_PG_DSN" "$NIMCACHE_BUILD/bin/ratingingest" "$@"
