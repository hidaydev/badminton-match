#!/bin/sh
# SEC-05: scan every lockfile the OSV database knows against published
# advisories, and fail on HIGH or CRITICAL.
#
#   ./task osv-scan
#
# `osv-scanner` reads `pnpm-lock.yaml` (the npm universe). It cannot read
# `deps.lock`: that file is this repository's own format, and OSV has no Nimble
# ecosystem to match a Nim package or commit against (verified against
# api.osv.dev, see docs/handbook/deps-format.md section 6). The Nim universe is
# pinned by commit and hashed by `./task deps-check` instead.
#
# The scanner is a CI-only tool pinned by version and sha256 in deps.lock
# (`release:` scheme); the workflow installs it before calling this target.
set -eu
. "$(dirname "$0")/lib.sh"

require_cmd osv-scanner
require_cmd nim

bin="$REPO_ROOT/.cache/$WORKTREE/bin/osvgate"
mkdir -p "$(dirname "$bin")"

report=$(mktemp "${TMPDIR:-/tmp}/majadu-osv.XXXXXX")
trap 'rm -f "$report"' EXIT HUP INT TERM

code=0
osv-scanner scan source --recursive --format=json --verbosity=error \
  --output-file="$report" "$REPO_ROOT" || code=$?
case "$code" in
  0|1) ;;
  *)
    # 0 is "nothing found" and 1 is "findings written"; anything else means the
    # scan itself did not happen, and a missing verdict must not read as clean.
    fail "osv-scanner exited $code without a report"
    ;;
esac

cd "$REPO_ROOT"
nim c $CHECK_FLAGS --nimcache:"$NIMCACHE_CHECK" -o:"$bin" tools/osvgate/main.nim
"$bin" "$report"
