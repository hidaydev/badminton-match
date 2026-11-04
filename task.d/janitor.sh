#!/bin/sh
. "$(dirname "$0")/lib.sh"

require_cmd psql

: "${MAJADU_PG_DSN:?MAJADU_PG_DSN is required (application role)}"

nim_build -o:"$NIMCACHE_BUILD/bin/janitorcli" tools/janitorcli/main.nim

MAJADU_PG_DSN="$MAJADU_PG_DSN" "$NIMCACHE_BUILD/bin/janitorcli"
