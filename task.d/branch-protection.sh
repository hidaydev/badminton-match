#!/bin/sh
# Verify the required status checks on a protected branch (QA-22).
#
# The aggregate "Gate" job in ci.yml does not depend on the Coverage workflow:
# GitHub cannot express a cross-workflow `needs`. Unless branch protection also
# requires "Coverage: ratchet", a pull request can merge with the ratchet red,
# and the ratchet is the only defence against the web threshold and the frozen
# files. This target reads the repository setting instead of trusting the doc.
#
#   ./task branch-protection [--branch main]
. "$(dirname "$0")/lib.sh"

branch=main
while [ "$#" -gt 0 ]; do
  case "$1" in
    --branch)
      [ "$#" -ge 2 ] || fail "--branch needs a name"
      branch=$2
      shift
      ;;
    -h|--help)
      printf 'usage: ./task branch-protection [--branch main]\n'
      exit 0
      ;;
    *) fail "unknown argument: $1" ;;
  esac
  shift
done

require_cmd gh
gh auth status >/dev/null 2>&1 ||
  fail "gh is not authenticated: run gh auth login, then ./task branch-protection"

repo=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null) ||
  fail "cannot resolve the repository from gh; run this inside the checkout"
[ -n "$repo" ] || fail "gh returned no repository"

contexts=$(gh api "repos/$repo/branches/$branch/protection/required_status_checks" \
  --jq '.contexts[]' 2>/dev/null) || fail "no required status checks on $branch, or the token cannot read branch protection"

status=0
for required in "Gate" "Coverage: ratchet"; do
  if printf '%s\n' "$contexts" | grep -qx "$required"; then
    printf 'branch-protection: %s requires %s\n' "$branch" "$required"
  else
    printf 'branch-protection: %s does not require %s (found: %s)\n' \
      "$branch" "$required" "$(printf '%s' "$contexts" | tr '\n' ',' | sed 's/,$//')" >&2
    status=1
  fi
done

[ "$status" -eq 0 ] || fail "add the missing check in Settings > Branches, then re-run"
printf 'branch-protection: ok\n'
