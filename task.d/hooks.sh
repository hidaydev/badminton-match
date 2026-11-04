#!/bin/sh
# Install the repository hooks (T-108). One command, idempotent.
. "$(dirname "$0")/lib.sh"

require_cmd git

git -C "$REPO_ROOT" config core.hooksPath .githooks
printf 'hooks installed: core.hooksPath=%s\n' \
  "$(git -C "$REPO_ROOT" config --get core.hooksPath)"
printf 'pre-push rejects docs/audits and docs/plan/reviews.\n'
