#!/bin/sh
# Bring an empty instance to a usable state without writing SQL by hand:
# migrations, L1 config seed, the first platform owner, a default community.
. "$(dirname "$0")/lib.sh"

require_cmd psql

: "${MAJADU_PG_DSN:?MAJADU_PG_DSN is required}"

if [ "$#" -eq 0 ]; then
  fail "usage: ./task bootstrap --sub <google-sub> [--email <address>]"
fi

nim_build -o:"$NIMCACHE_BUILD/bin/dbtools" tools/dbtools/main.nim
nim_build -o:"$NIMCACHE_BUILD/bin/ownerseed" tools/ownerseed/main.nim

MAJADU_PG_DSN="$MAJADU_PG_DSN" "$NIMCACHE_BUILD/bin/dbtools" \
  migrate --dir "$REPO_ROOT/db/migrations"
MAJADU_PG_DSN="$MAJADU_PG_DSN" "$NIMCACHE_BUILD/bin/dbtools" \
  seed --dir "$REPO_ROOT/db/seeds"
MAJADU_PG_DSN="$MAJADU_PG_DSN" "$NIMCACHE_BUILD/bin/ownerseed" "$@"
