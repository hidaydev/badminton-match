#!/bin/sh
# Prove the two engines the browser suite drives can actually start.
#
# This replaces the fallback that used to sit in the `install browsers` step:
# when a launch failed it ran `playwright install --with-deps` and hoped apt
# would finish inside the job. On 2026-11-18 it did not, and the job died at the
# 15-minute cap with the real cause — a missing `libevent-2.1.so.7` — twelve
# minutes above the only line that named it.
#
# A poisoned browser cache is a different failure and gets its own sentence, so
# a red run says which one happened.
set -eu

. "$(dirname "$0")/lib.sh"

require_cmd node

# The engine list follows e2e/browsers.ts: chromium for the phone and desktop
# projects, webkit for the iPhone project. Firefox is pinned and downloaded
# because `./task deps-check` requires it, but no project starts it.
tmp=$(mktemp "${TMPDIR:-/tmp}/majadu-browser-check.XXXXXX.log")
trap 'rm -f "$tmp"' EXIT INT TERM

if pnpm --filter badminton-pair-tmp exec node -e \
  "const {chromium,webkit}=require('playwright');(async()=>{for(const engine of [chromium,webkit]){const browser=await engine.launch();const page=await browser.newPage();await page.goto('data:text/html,ok');await browser.close();console.log(engine.name()+' started')}})()" \
  >"$tmp" 2>&1; then
  sed -e 's/^/browser-check: /' "$tmp"
  printf 'browser-check: ok\n'
  exit 0
fi

sed -e 's/^/browser-check: /' "$tmp" >&2

# The loader line is the actionable one: `MiniBrowser: error while loading
# shared libraries: libevent-2.1.so.7: cannot open shared object file`.
libs=$(sed -n 's/.*error while loading shared libraries: \([^:]*\):.*/\1/p' "$tmp" |
  LC_ALL=C sort -u | tr '\n' ' ' | sed -e 's/ *$//')

if [ -n "$libs" ]; then
  printf '::error::browser-check: a browser cannot start; missing shared library: %s\n' "$libs" >&2
  printf 'browser-check: the library above is missing from this runner, so the browser binaries are fine and the system packages are not. Add its package to e2e/system-deps.txt, or install it with ./task browser-deps after fixing the mirror.\n' >&2
  exit 1
fi

printf '::error::browser-check: a browser failed to launch without a missing-library line; see the output above (a stale ~/.cache/ms-playwright entry is the usual cause)\n' >&2
exit 1
