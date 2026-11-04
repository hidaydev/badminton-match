#!/bin/sh
# Rehearsal harness (T-063). `run` needs a VPS; `check` reads the committed
# timings and needs nothing.
. "$(dirname "$0")/lib.sh"

require_cmd bash
exec bash "$REPO_ROOT/tools/rehearsal/rehearse.sh" "$@"
