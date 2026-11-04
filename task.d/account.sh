#!/bin/sh
# Close and anonymise an account (owner-only, run from the VPS).
. "$(dirname "$0")/lib.sh"

: "${MAJADU_PG_DSN:?MAJADU_PG_DSN is required}"

nim_build -o:"$NIMCACHE_BUILD/bin/accountlifecycle" tools/accountlifecycle/main.nim

MAJADU_PG_DSN="$MAJADU_PG_DSN" "$NIMCACHE_BUILD/bin/accountlifecycle" "$@"
