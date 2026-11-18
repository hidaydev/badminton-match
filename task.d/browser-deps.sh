#!/bin/sh
# The system libraries the Playwright browsers need, installed from a pinned
# list instead of `playwright install --with-deps`.
#
# `--with-deps` asks apt for Playwright's dependency names and lets apt resolve
# every Recommends: on the ubuntu-24.04 runner that was 181 packages and 125 MB.
# On 2026-11-18 a slow mirror spent 13m47s on it and the 15-minute job cap
# cancelled the job before a single test ran. This target installs the exact
# list in e2e/system-deps.txt with `--no-install-recommends`, which is 62
# packages when the runner image has nothing, and skips apt entirely when a
# cached package set already satisfies it.
#
# Two things this target guarantees that `--with-deps` did not:
#
# 1. A missing library is named. Every apt request is bounded, and the launch
#    probe reports the shared object that would not load instead of hanging.
# 2. A slow mirror fails fast. `MAJADU_BROWSER_DEPS_TIMEOUT` (default 300s)
#    caps the whole apt run, so a job can never again spend its budget inside
#    this step. The 15-minute job contract is unchanged.
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

# A warm runner image already has most of these, and `dpkg -s` answers in
# milliseconds. Anything missing decides whether apt runs at all.
missing=""
for pkg in $packages; do
  if ! dpkg -s "$pkg" >/dev/null 2>&1; then
    missing="$missing $pkg"
  fi
done
missing=$(printf '%s' "$missing" | sed -e 's/^ *//')

if [ -z "$missing" ]; then
  # shellcheck disable=SC2086 # packages is a newline list on purpose
  count=$(printf '%s\n' $packages | wc -l | tr -d ' ')
  printf 'browser-deps: all %s packages already installed\n' "$count"
  exit 0
fi

# shellcheck disable=SC2086 # missing is a newline list on purpose
count=$(printf '%s\n' $missing | wc -l | tr -d ' ')
printf 'browser-deps: installing %s missing package(s)\n' "$count"
printf 'browser-deps: %s\n' "$missing"

# Each request is bounded so a stalled mirror fails over or fails fast, and the
# whole run is capped because the job's 15 minutes are not this step's to spend.
budget=${MAJADU_BROWSER_DEPS_TIMEOUT:-300}
apt_opts="-o Acquire::Retries=3 -o Acquire::http::Timeout=15 -o Acquire::https::Timeout=15"
apt_get="apt-get -y -qq --no-install-recommends $apt_opts"

# shellcheck disable=SC2086 # apt_opts is a list of -o options on purpose
# MAJADU_BROWSER_DEPS_CACHE names a directory the workflow restores, keyed by a
# hash of the list above. A hit installs from disk with `--no-download`, so the
# packages never come from a mirror; a miss fills it once with `--download-only`.
# Without the variable the step is what it always was: one bounded online install.
cache=${MAJADU_BROWSER_DEPS_CACHE:-}
cache_opt=""
offline=""
if [ -n "$cache" ]; then
  mkdir -p "$cache"
  cache_opt="-o Dir::Cache::archives=$cache"
  offline="--no-download"
  if [ -n "$(find "$cache" -maxdepth 1 -name '*.deb' -print -quit 2>/dev/null)" ]; then
    printf 'browser-deps: installing from the restored deb cache in %s\n' "$cache"
    # A restored cache still needs the package index to resolve names. When the
    # runner has none, only the index is fetched: the 125 MB of packages stay
    # on disk, so a slow mirror cannot decide this step either way.
    # shellcheck disable=SC2086
    if ! sudo $apt_get $cache_opt --no-download --simulate install $missing >/dev/null 2>&1; then
      printf 'browser-deps: the package index is absent or stale; fetching only the index\n'
      if ! timeout "$budget" sudo apt-get update -qq $apt_opts; then
        fail "apt-get update did not finish in ${budget}s (slow or unreachable mirror); a missing library will be named below if the browsers cannot start"
      fi
    fi
  else
    printf 'browser-deps: deb cache is empty; downloading the set once into %s\n' "$cache"
    if ! timeout "$budget" sudo apt-get update -qq $apt_opts; then
      fail "apt-get update did not finish in ${budget}s (slow or unreachable mirror); a missing library will be named below if the browsers cannot start"
    fi
    # shellcheck disable=SC2086 # cache_opt is an option list on purpose
    if ! timeout "$budget" sudo $apt_get $cache_opt install --download-only $missing; then
      fail "downloading the browser system libraries did not finish in ${budget}s: $missing"
    fi
  fi
elif ! timeout "$budget" sudo apt-get update -qq $apt_opts; then
  fail "apt-get update did not finish in ${budget}s (slow or unreachable mirror); a missing library will be named below if the browsers cannot start"
fi

# `timeout` on the install too: a half-written dpkg state is repaired by the
# next apt run, an exhausted job budget is not.
# shellcheck disable=SC2086
if ! timeout "$budget" sudo $apt_get $cache_opt $offline install $missing; then
  fail "installing the browser system libraries did not finish in ${budget}s: $missing"
fi

still_missing=""
for pkg in $packages; do
  if ! dpkg -s "$pkg" >/dev/null 2>&1; then
    still_missing="$still_missing $pkg"
  fi
done
if [ -n "$(printf '%s' "$still_missing" | tr -d ' ')" ]; then
  fail "apt reported success but these packages are still absent:$still_missing"
fi
printf 'browser-deps: ok (%s packages installed)\n' "$count"
