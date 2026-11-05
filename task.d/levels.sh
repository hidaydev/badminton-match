#!/bin/sh
# Read or write the tournament point ladder (rating.levels).
. "$(dirname "$0")/lib.sh"

: "${MAJADU_PG_DSN:?MAJADU_PG_DSN is required}"

nim_build -o:"$NIMCACHE_BUILD/bin/ratinglevels" tools/ratinglevels/main.nim

MAJADU_PG_DSN="$MAJADU_PG_DSN" "$NIMCACHE_BUILD/bin/ratinglevels" "$@"