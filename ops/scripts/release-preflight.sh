#!/usr/bin/env bash
# Check every prerequisite of a release before the first real one runs.
#
#   ops/scripts/release-preflight.sh v2.0.0
#
# The release pipeline has never completed end to end: no tag, no release body,
# no digest and no deploy has happened. This script walks the same inputs the
# workflow and the deploy will read and names the one that is missing, so the
# first execution is a rehearsal instead of a discovery.
#
# It is read-only: it creates no tag, pushes nothing and pulls no image. Run it
# from the release checkout, with the VPS env files reachable through
# MAJADU_APP_DIR when the operator runs it on the host.
#
# Exit codes: 0 every check passed, 1 at least one check failed, 2 usage.
set -Eeuo pipefail

umask 077

TAG="${1:-}"
if [ -z "$TAG" ]; then
  sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//' >&2
  exit 2
fi

REPO_DIR="${MAJADU_REPO_DIR:-$(cd "$(dirname "$0")/../.." && pwd)}"
APP_DIR="${MAJADU_APP_DIR:-/srv/qouver/apps/majadu}"
GITHUB_REPO="${MAJADU_GITHUB_REPO:-hidaydev/badminton-match}"
REGISTRY_IMAGE="${MAJADU_REGISTRY_IMAGE:-ghcr.io/hidaydev/badminton-match}"
TOKEN_FILE="$APP_DIR/env/ghcr-token"
COSIGN_PUB="$APP_DIR/env/cosign.pub"

failures=0
ok() { printf 'ok: %s\n' "$*"; }
missing() { printf 'MISSING: %s\n' "$*" >&2; failures=$((failures + 1)); }

file_mode() {
  stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null || echo "?"
}

require_private() {
  local path="$1" mode
  if [ ! -f "$path" ]; then
    missing "$path is not installed"
    return 0
  fi
  mode=$(file_mode "$path")
  case "$mode" in
    600|400) ok "$path is mode $mode" ;;
    *) missing "$path must be mode 600 (found $mode)" ;;
  esac
}

release_body() {
  local token=""
  if [ -f "$TOKEN_FILE" ]; then
    IFS= read -r token <"$TOKEN_FILE" || true
  elif [ -n "${GITHUB_TOKEN:-}" ]; then
    token="$GITHUB_TOKEN"
  fi
  if [ -n "$token" ]; then
    curl -fsS --max-time 20 -H "Accept: application/vnd.github+json" \
      --config - "https://api.github.com/repos/$GITHUB_REPO/releases/tags/$TAG" <<EOF
header = "Authorization: Bearer $token"
EOF
  else
    curl -fsS --max-time 20 -H "Accept: application/vnd.github+json" \
      "https://api.github.com/repos/$GITHUB_REPO/releases/tags/$TAG"
  fi
}

# ---------------------------------------------------------------------------
# 1. The tag and VERSION have to name the same release.
# ---------------------------------------------------------------------------
version=$(tr -d '[:space:]' <"$REPO_DIR/VERSION")
if [ "v$version" = "$TAG" ]; then
  ok "VERSION is $version, tag is $TAG"
else
  missing "VERSION is $version but the tag is $TAG"
fi

if git -C "$REPO_DIR" rev-parse -q --verify "refs/tags/$TAG" >/dev/null 2>&1; then
  ok "tag $TAG exists"
  if git -C "$REPO_DIR" verify-tag "$TAG" >/dev/null 2>&1; then
    ok "tag $TAG is signed and verifies"
  else
    missing "tag $TAG does not verify; sign it with git tag -s and install a signing key"
  fi
else
  missing "tag $TAG does not exist; the release workflow runs from the tag, not from main"
fi

# The committed allowed_signers file is the offline path release.yml prefers.
# Without it the workflow falls back to GitHub's verification of the account's
# SSH keys, which works but leaves the repository unable to verify a tag itself.
if [ -f "$REPO_DIR/.github/allowed_signers" ]; then
  ok ".github/allowed_signers is committed"
else
  printf 'warn: .github/allowed_signers is not committed; release.yml will verify the tag through the GitHub API\n' >&2
fi

# ---------------------------------------------------------------------------
# 2. The release body has to carry exactly one digest line.
# ---------------------------------------------------------------------------
if body=$(release_body 2>/dev/null); then
  markers=$(printf '%s' "$body" |
    grep -oE 'digest:[[:space:]]*sha256:[0-9a-f]{64}' || true)
  marker_count=$(printf '%s\n' "$markers" | grep -c 'sha256:' || true)
  strings=$(printf '%s' "$body" | grep -oE 'sha256:[0-9a-f]{64}' || true)
  string_count=$(printf '%s\n' "$strings" | grep -c 'sha256:' || true)
  if [ "$marker_count" -eq 1 ] && [ "$string_count" -eq 1 ]; then
    DIGEST="sha256:${markers#*sha256:}"
    ok "release $TAG publishes exactly one digest"
  else
    missing "release $TAG must carry exactly one digest line (found $marker_count marker(s), $string_count sha256 string(s))"
  fi
else
  missing "release $TAG is not published; release.yml has to produce it first"
fi

# ---------------------------------------------------------------------------
# 3. The signature and the deploy inputs.
# ---------------------------------------------------------------------------
if command -v cosign >/dev/null 2>&1; then
  ok "cosign is installed"
  if [ -n "${DIGEST:-}" ]; then
    require_private "$COSIGN_PUB"
    if [ -f "$COSIGN_PUB" ] &&
      cosign verify --key "$COSIGN_PUB" "$REGISTRY_IMAGE@$DIGEST" >/dev/null 2>&1; then
      ok "$REGISTRY_IMAGE@$DIGEST verifies with $COSIGN_PUB"
    else
      missing "cosign could not verify $REGISTRY_IMAGE@$DIGEST with $COSIGN_PUB"
    fi
  fi
else
  missing "cosign is not installed; the deploy refuses a digest it cannot verify"
fi

require_private "$APP_DIR/env/majadu-prod.env"
require_private "$APP_DIR/env/majadu-tools.env"
require_private "$TOKEN_FILE"

# ---------------------------------------------------------------------------
# 4. The result.
# ---------------------------------------------------------------------------
if [ "$failures" -ne 0 ]; then
  printf '\npreflight: %d problem(s); the release must not be cut yet\n' "$failures" >&2
  exit 1
fi
printf '\npreflight: ready; record the rehearsal in docs/ops/release.md section 7\n'
