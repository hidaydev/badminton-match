#!/bin/sh
# GITLEAKS: scan the whole history, not the range a push event happens to name.
#
#   ./task secrets-history
#
# `gitleaks-action` scans `--no-merges --first-parent base^..head` on a push or
# a pull request. This branch is built from merges, so that range is a couple of
# commits out of the whole tree and a secret that arrived inside a merged wave
# branch is outside it: the gate reports clean because it never looked. This
# target scans every commit reachable from every ref with the same repository
# config, so the range is never what decides whether a finding exists.
#
# The scanner is a release asset pinned by version and by the sha256 recorded in
# deps.lock (`release:` scheme); CI installs exactly that file before calling
# this target, and `./task deps-check` fails when the two disagree.
set -eu
. "$(dirname "$0")/lib.sh"

require_cmd gitleaks
require_cmd git

CONFIG="$REPO_ROOT/.gitleaks.toml"
[ -f "$CONFIG" ] || fail "missing $CONFIG"

# The report is written to a temp file and never kept: `--redact` covers the log
# output only, so the JSON holds the raw value. Printing the console form is
# enough to name the commit, the path and the rule without a second copy of the
# secret on disk.
report=$(mktemp "${TMPDIR:-/tmp}/majadu-secrets.XXXXXX.json")
trap 'rm -f "$report"' EXIT HUP INT TERM

code=0
gitleaks git --no-banner --redact --config "$CONFIG" \
  --report-format json --report-path "$report" \
  --log-opts="--all --full-history" "$REPO_ROOT" || code=$?
case "$code" in
  0) ;;
  1)
    printf 'secrets-history: a finding exists somewhere in the history (see above);\n' >&2
    printf 'secrets-history: rotate the credential, then land the removal in git history\n' >&2
    exit 1
    ;;
  *)
    # Anything but 0 and 1 means the scan did not produce a verdict, and a scan
    # that did not run must not read as clean.
    fail "gitleaks exited $code without a verdict"
    ;;
esac

printf 'secrets-history: ok (%s commits in the reachable graph)\n' \
  "$(git -C "$REPO_ROOT" rev-list --all --count)"
