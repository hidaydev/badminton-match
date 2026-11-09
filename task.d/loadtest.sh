#!/bin/sh
# Run the committed load test against a live endpoint.
#
#   ./task loadtest --http https://api.qouver.com/majadu/readyz \
#     --requests 10000 --concurrency 50
#
# The record of the run is what fills the measured column in the capacity
# statement (docs/ops/operations.md). It needs a reachable API and, for the
# watcher half, a file of single-use watcher URLs.
. "$(dirname "$0")/lib.sh"

require_cmd node
exec node "$REPO_ROOT/ops/scripts/loadtest.mjs" "$@"
