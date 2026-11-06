#!/usr/bin/env bash
# Route one GitHub push to the deploy script that owns its ref.
#
# The repository has a single webhook (majadu-monorepo) pointing at this file,
# because the remote does not allow adding another one. The hook fires for every
# push and passes the repository name and the ref; this script decides which
# instance the push belongs to.
#
#   refs/heads/main                 -> production (deploy-vps.sh, digest GHCR)
#   refs/heads/release/2.0.0-rc.1   -> RC (deploy-vps-rc.sh, build on the VPS)
#
# Anything else exits 0 without touching either instance. Both target scripts
# also guard their own ref, so a routing mistake here cannot deploy the wrong
# branch: it can only skip a deploy.
#
# Installed at /srv/qouver/apps/majadu/scripts/deploy-dispatch.sh and kept in
# sync by deploy-vps.sh's script-sync step.
set -euo pipefail

REPO_NAME="${1:-}"
REF="${2:-}"

HERE=$(dirname "$0")
PROD_SCRIPT="$HERE/deploy-vps.sh"
RC_APP_DIR="${MAJADU_RC_APP_DIR:-/srv/qouver/apps/majadu-rc}"
RC_SCRIPT="$RC_APP_DIR/scripts/deploy-vps-rc.sh"

case "$REF" in
  refs/heads/main)
    [ -x "$PROD_SCRIPT" ] || { echo "dispatch: $PROD_SCRIPT is missing"; exit 1; }
    exec "$PROD_SCRIPT" "$REPO_NAME" "$REF"
    ;;
  refs/heads/release/2.0.0-rc.1)
    # Before bootstrap the instance does not exist. Skipping is the safe answer:
    # the branch can be pushed before the database is prepared, and the deploy
    # starts working on its own once the env file is in place.
    if [ ! -f "$RC_APP_DIR/env/majadu-rc.env" ]; then
      echo "dispatch: $RC_APP_DIR is not bootstrapped yet; nothing to deploy"
      exit 0
    fi
    [ -x "$RC_SCRIPT" ] || { echo "dispatch: $RC_SCRIPT is missing"; exit 1; }
    exec "$RC_SCRIPT" "$REPO_NAME" "$REF"
    ;;
  *)
    echo "dispatch: ref '${REF:-<empty>}' has no target; nothing to deploy"
    exit 0
    ;;
esac