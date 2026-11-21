#!/usr/bin/env bash
# Route one GitHub push to the deploy script that owns its ref.
#
# The repository has a single webhook (majadu-monorepo) pointing at this file,
# because the remote does not allow adding another one. The hook fires for every
# push and passes the repository name and the ref; this script decides which
# instance the push belongs to.
#
#   refs/heads/main                 -> production (deploy-vps.sh, digest GHCR)
#
# Anything else exits 0 without deploying. The target script also guards its own
# ref, so a routing mistake here cannot deploy the wrong branch: it can only
# skip a deploy.
#
# The RC instance (release/2.0.0-rc.1, deploy-vps-rc.sh, /srv/qouver/apps/
# majadu-rc, database bm2_rc) was purged on 2026-11-21 by the owner's order. Its
# branch is no longer routed anywhere, which is the intended state: a push to it
# exits 0 here instead of failing a webhook.
#
# Installed at /srv/qouver/apps/majadu/scripts/deploy-dispatch.sh and kept in
# sync by deploy-vps.sh's script-sync step.
set -euo pipefail

REPO_NAME="${1:-}"
REF="${2:-}"

HERE=$(dirname "$0")
PROD_SCRIPT="$HERE/deploy-vps.sh"

case "$REF" in
  refs/heads/main)
    [ -x "$PROD_SCRIPT" ] || { echo "dispatch: $PROD_SCRIPT is missing"; exit 1; }
    exec "$PROD_SCRIPT" "$REPO_NAME" "$REF"
    ;;
  *)
    echo "dispatch: ref '${REF:-<empty>}' has no target; nothing to deploy"
    exit 0
    ;;
esac