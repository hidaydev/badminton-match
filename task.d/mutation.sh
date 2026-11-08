#!/bin/sh
# Mutation testing (QA-05, D-14). No database and no network: each mutant runs
# the owning unit suite against a scratch copy of one file, and the file is
# restored even when the run is interrupted.
. "$(dirname "$0")/lib.sh"

require_cmd nim

exec nim c -r --hints:off --nimcache:"$NIMCACHE_BUILD/mutation" \
  -o:"$NIMCACHE_BUILD/bin/majadu-mutation" "$REPO_ROOT/tools/mutation/main.nim" "$@"