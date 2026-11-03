#!/bin/sh
. "$(dirname "$0")/lib.sh"

require_cmd psql
sh "$REPO_ROOT/ops/dev/pg-up.sh"
