#!/bin/sh
# The system packages the Playwright browsers need, installed in their own step
# instead of inside `playwright install --with-deps`.
#
# The package set is deliberately the same one. e2e/system-deps.txt is the
# `tools`, `chromium`, `firefox` and `webkit` arrays of the Playwright build
# pinned in deps.lock, installed with Recommends on, which is what
# `--with-deps` asks apt for. Narrowing it is not free: with Recommends off the
# font set drops from 117 to 8, and without the firefox group the scoreboard's
# `⛶` control falls through to a different face and renders as a box. The
# committed visual baselines were recorded against the full set, so the install
# has to reproduce it.
#
# What changes is that this step can no longer consume the job:
#
# 1. The whole apt run is capped by MAJADU_BROWSER_DEPS_TIMEOUT, and each
#    invocation is distinguished: a cap (timeout, exit 124) says so, and any
#    other failure reports apt's own exit code. On 2026-11-18 `--with-deps`
#    spent 13m47s here and the 15-minute job cap cancelled the job before a
#    single test ran (CI 44267955982, release 44267937137).
# 2. The downloaded .deb set is cached through MAJADU_BROWSER_DEPS_CACHE. A
#    cold run fills it; later runs install from those files and never touch a
#    mirror, so a slow mirror costs one run instead of every run. A cache that
#    apt cannot satisfy falls back to a bounded online install rather than
#    failing the job.
set -eu

# `./task browser-deps` provides REPO_ROOT and the shared helpers.
. "$(dirname "$0")/lib.sh"

LIST="$REPO_ROOT/e2e/system-deps.txt"
[ -f "$LIST" ] || fail "missing $LIST"

# The list describes Linux packages; a developer machine using its own browser
# install needs none of it.
if [ "$(uname -s)" != "Linux" ]; then
  printf 'browser-deps: not Linux, nothing to install\n'
  exit 0
fi

packages=$(sed -e 's/#.*$//' "$LIST" | tr -s ' \t' '\n' | sed -e '/^$/d' | LC_ALL=C sort -u)
[ -n "$packages" ] || fail "$LIST names no packages"
# shellcheck disable=SC2086 # packages is a newline list on purpose
total=$(printf '%s\n' $packages | wc -l | tr -d ' ')

# A warm runner image already carries most of these and `dpkg -s` answers in
# milliseconds, so the offline fast path only needs to know what is absent.
missing=""
for pkg in $packages; do
  if ! dpkg -s "$pkg" >/dev/null 2>&1; then
    missing="$missing $pkg"
  fi
done
missing=$(printf '%s' "$missing" | sed -e 's/^ *//')

# 420s is under a third of the job's 15 minutes: enough for a cold download on a
# working mirror, small enough that a stuck one still leaves the suite its four.
budget=${MAJADU_BROWSER_DEPS_TIMEOUT:-420}
apt_opts="-o Acquire::Retries=3 -o Acquire::http::Timeout=15 -o Acquire::https::Timeout=15"
apt_get="apt-get -y -qq $apt_opts"
cache=${MAJADU_BROWSER_DEPS_CACHE:-}

# 0. Nothing to do: every pinned package is on disk and there is no cache to
#    seed. Reaching a mirror here would only re-resolve a set that is already
#    resolved, and a warm runner is the common case.
if [ -z "$missing" ] &&
  { [ -z "$cache" ] || [ -z "$(find "$cache" -maxdepth 1 -name '*.deb' -print -quit 2>/dev/null)" ]; }; then
  printf 'browser-deps: all %s packages already installed\n' "$total"
  exit 0
fi

# `timeout` exits 124 when the cap is what stopped the command; any other code
# is apt's own failure and is reported as that. Collapsing the two would blame a
# slow mirror for an unresolvable host, which is a different fix.
run_apt() {
  _step=$1
  shift
  _code=0
  # shellcheck disable=SC2086 # option lists on purpose
  timeout "$budget" "$@" || _code=$?
  [ "$_code" -eq 0 ] && return 0
  if [ "$_code" -eq 124 ]; then
    fail "$_step did not finish in ${budget}s; the mirror is too slow for this step. Raise MAJADU_BROWSER_DEPS_TIMEOUT, or let a run seed MAJADU_BROWSER_DEPS_CACHE so later runs install from disk"
  fi
  fail "$_step failed with exit $_code (apt output above); the pinned packages were: $(printf '%s' "$packages" | tr '\n' ' ')"
}

# 1. A cache hit installs from disk. `--no-download` refuses to reach a mirror;
#    when the cached set cannot satisfy the current lists apt exits fast and we
#    fall through to the online path instead of failing the job.
if [ -n "$cache" ] &&
  [ -n "$(find "$cache" -maxdepth 1 -name '*.deb' -print -quit 2>/dev/null)" ]; then
  printf 'browser-deps: trying the cached .deb set in %s\n' "$cache"
  if timeout "$budget" sudo $apt_get \
    -o Dir::Cache::archives="$cache" --no-download install $packages; then
    printf 'browser-deps: ok (%s packages installed from cache)\n' "$total"
    exit 0
  fi
  printf 'browser-deps: the cached set did not satisfy apt; falling back to a bounded online install\n'
fi

# 2. The online path. `apt-get update` is only paid when the cache could not
#    answer, and the download step fills the cache for next time.
run_apt "apt-get update" sudo apt-get update -qq $apt_opts

if [ -n "$cache" ]; then
  mkdir -p "$cache"
  printf 'browser-deps: seeding the .deb cache in %s\n' "$cache"
  run_apt "downloading the browser package set" \
    sudo $apt_get -o Dir::Cache::archives="$cache" install --download-only $packages
  run_apt "installing the browser package set" \
    sudo $apt_get -o Dir::Cache::archives="$cache" --no-download install $packages
else
  run_apt "installing the browser package set" sudo $apt_get install $packages
fi

# apt exiting 0 is not proof the packages are on disk.
still_missing=""
for pkg in $packages; do
  if ! dpkg -s "$pkg" >/dev/null 2>&1; then
    still_missing="$still_missing $pkg"
  fi
done
if [ -n "$(printf '%s' "$still_missing" | tr -d ' ')" ]; then
  fail "apt reported success but these packages are still absent:$still_missing"
fi
printf 'browser-deps: ok (%s packages installed)\n' "$total"
