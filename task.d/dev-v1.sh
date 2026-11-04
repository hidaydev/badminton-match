#!/bin/sh
. "$(dirname "$0")/lib.sh"

require_cmd psql
sh "$REPO_ROOT/ops/dev/v1/up.sh"
