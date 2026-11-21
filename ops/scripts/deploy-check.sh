#!/usr/bin/env bash
# Reconcile the latest GitHub release with the version this host has installed.
#
#   ./ops/scripts/deploy-check.sh
#
# GitHub disables a webhook after repeated delivery failures, and a webhook that
# never arrived looks identical to "nothing to deploy": the version gate in
# deploy-vps.sh exits 0 in both cases. This check is the independent comparison.
# It runs from majadu-deploy-check.timer every hour; a mismatch that is older
# than one hour pages through majadu-alert@deploy-check.service.
#
# Env: MAJADU_APP_DIR, MAJADU_GITHUB_REPO, MAJADU_STATE_DIR,
#      MAJADU_DEPLOY_CHECK_MAX_AGE (minutes, default 60),
#      MAJADU_SYSTEMCTL_CMD.
set -Eeuo pipefail

APP_DIR="${MAJADU_APP_DIR:-/srv/qouver/apps/majadu}"
GITHUB_REPO="${MAJADU_GITHUB_REPO:-hidaydev/badminton-match}"
STATE_DIR="${MAJADU_STATE_DIR:-$APP_DIR/deploy}"
TOKEN_FILE="$APP_DIR/env/ghcr-token"
MAX_AGE="${MAJADU_DEPLOY_CHECK_MAX_AGE:-60}"
SYSTEMCTL="${MAJADU_SYSTEMCTL_CMD:-systemctl --user}"

log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }

alert() {
  if $SYSTEMCTL list-unit-files 'majadu-alert@.service' >/dev/null 2>&1; then
    $SYSTEMCTL start majadu-alert@deploy-check.service >/dev/null 2>&1 || true
  fi
}

case "$MAX_AGE" in
  ''|*[!0-9]*) log "ERROR: MAJADU_DEPLOY_CHECK_MAX_AGE must be a whole number"; exit 1 ;;
esac

auth=()
if [ -f "$TOKEN_FILE" ]; then
  auth=(--config -)
  read -r token <"$TOKEN_FILE" || true
fi

if [ "${#auth[@]}" -gt 0 ]; then
  body=$(curl -fsS --max-time 20 -H "Accept: application/vnd.github+json" \
    "${auth[@]}" "https://api.github.com/repos/$GITHUB_REPO/releases/latest" \
    <<EOF 2>/dev/null || true
header = "Authorization: Bearer $token"
EOF
  )
else
  body=$(curl -fsS --max-time 20 -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/$GITHUB_REPO/releases/latest" 2>/dev/null || true)
fi

latest=$(printf '%s' "$body" |
  sed -n 's/.*"tag_name":[[:space:]]*"v\([^"]*\)".*/\1/p' | head -1 || true)
if [ -z "$latest" ]; then
  log "ERROR: cannot read the latest release tag from api.github.com"
  alert
  exit 1
fi

deployed=""
[ -f "$STATE_DIR/deployed-version" ] &&
  deployed=$(tr -d '[:space:]' <"$STATE_DIR/deployed-version")

# REL-DEP-01: the version string alone cannot tell whether the running commit is
# the release. A hotfix merged after the tag keeps VERSION unchanged, so this
# check used to report "matches" while the host served code the release never
# contained -- and a rollback decided from /version would pick the wrong tree.
# The comparison is "at or after the tag", not equality: this repo deploys
# `main`, so a deployed revision ten commits past the tag is normal. Anything
# that is not a descendant (diverged, or older than the tag) is drift.
gh_get() {
  if [ "${#auth[@]}" -gt 0 ]; then
    curl -fsS --max-time 20 -H "Accept: application/vnd.github+json" "${auth[@]}" \
      "https://api.github.com/repos/$GITHUB_REPO/$1" <<EOF 2>/dev/null || true
header = "Authorization: Bearer $token"
EOF
  else
    curl -fsS --max-time 20 -H "Accept: application/vnd.github+json" \
      "https://api.github.com/repos/$GITHUB_REPO/$1" 2>/dev/null || true
  fi
}

rev_status="unknown"
deployed_rev=""
[ -f "$STATE_DIR/deployed-rev" ] &&
  deployed_rev=$(tr -d '[:space:]' <"$STATE_DIR/deployed-rev")

if [ "$deployed" = "$latest" ] && [ -n "$deployed_rev" ]; then
  tag_commit=$(gh_get "commits/v$(printf '%s' "$latest")" |
    sed -n 's/.*"sha":[[:space:]]*"\([0-9a-f]\{40\}\)".*/\1/p' | head -1 || true)
  if [ -n "$tag_commit" ]; then
    rev_status=$(gh_get "compare/${tag_commit}...${deployed_rev}" |
      sed -n 's/.*"status":[[:space:]]*"\([a-z]*\)".*/\1/p' | head -1 || true)
  fi
fi

if [ "$deployed" = "$latest" ]; then
  case "$rev_status" in
    ahead|identical)
      log "deployed version $deployed matches the latest release; rev $deployed_rev is $rev_status of the v$latest tag"
      exit 0
      ;;
    diverged|behind)
      log "ERROR: latest release is v$latest but the deployed rev $deployed_rev is $rev_status the tag, not at or after it"
      alert
      exit 1
      ;;
    *)
      # The comparison is best effort: an API hiccup must not page, or a rate
      # limit would look like drift. The version match alone is the gate.
      log "deployed version $deployed matches the latest release (rev comparison unavailable: ${rev_status})"
      exit 0
      ;;
  esac
fi

# A webhook delivery is in flight until one hour has passed since the last
# successful release record. Only after that window is a mismatch drift.
if [ -f "$STATE_DIR/last-release.json" ] &&
  [ -z "$(find "$STATE_DIR/last-release.json" -mmin +"$MAX_AGE" -print 2>/dev/null)" ]; then
  log "release $latest is not deployed yet; the last release record is younger than ${MAX_AGE}m"
  exit 0
fi

log "ERROR: latest release is '$latest' but this host serves '${deployed:-<none>}'"
alert
exit 1
