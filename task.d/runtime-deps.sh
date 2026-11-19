#!/bin/sh
# The system packages a Nim or coverage job needs: the PCRE 1 runtime Nim's `re`
# binds to, and the Perl modules lcov 2.6 loads at startup.
#
# This came from `./task browser-deps`, because it is the same problem measured
# in a cheaper-looking step. The apt block it replaces ran in five jobs with
# `dpkg -s` and no cache, and on main 44478153535 it cost 186s in
# `API: integration (shard 1)`, 117s in `E2E: browser` and 87s in
# `Contract: corpora`. Across the last ten main runs it averages 30 to 44s in
# each of the jobs that install it, which is three to four runner-minutes per
# push spent resolving packages the job uses for one shared library.
#
# What changes is where the bytes come from, not which packages land:
#
# 1. The set is pinned in ops/ci/runtime-packages.txt, so the list is reviewable
#    and the workflow cannot drift from it.
# 2. The downloaded .deb set is cached through MAJADU_RUNTIME_DEPS_CACHE. A cold
#    run fills it; later runs install from those files with `--no-download` and
#    never open a mirror, so a slow mirror costs one run instead of every job of
#    every run. A cache apt cannot satisfy falls back to a bounded online
#    install instead of failing the job.
# 3. Each request is bounded by MAJADU_RUNTIME_DEPS_TIMEOUT, and a cap is
#    reported as a cap rather than as apt's exit code.
set -eu

# `./task runtime-deps` provides REPO_ROOT and the shared helpers.
. "$(dirname "$0")/lib.sh"

LIST="$REPO_ROOT/ops/ci/runtime-packages.txt"
[ -f "$LIST" ] || fail "missing $LIST"

# The list describes Linux packages; a developer machine uses its own runtime.
if [ "$(uname -s)" != "Linux" ]; then
  printf 'runtime-deps: not Linux, nothing to install\n'
  exit 0
fi

packages=$(sed -e 's/#.*$//' "$LIST" | tr -s ' \t' '\n' | sed -e '/^$/d' | LC_ALL=C sort -u)
[ -n "$packages" ] || fail "$LIST names no packages"
# shellcheck disable=SC2086 # packages is a newline list on purpose
total=$(printf '%s\n' $packages | wc -l | tr -d ' ')

# `dpkg -s` answers in milliseconds, so the fast path only has to know what is
# absent. This is the warm-runner case and it stays a no-op.
missing=""
for pkg in $packages; do
  if ! dpkg -s "$pkg" >/dev/null 2>&1; then
    missing="$missing $pkg"
  fi
done
missing=$(printf '%s' "$missing" | sed -e 's/^ *//')

# 180s is a sixth of the job's 15 minutes: enough for a cold download on a
# working mirror, small enough that a stuck one fails here instead of eating the
# budget the job was started for.
budget=${MAJADU_RUNTIME_DEPS_TIMEOUT:-180}
apt_opts="-o Acquire::Retries=3 -o Acquire::http::Timeout=15 -o Acquire::https::Timeout=15"
apt_get="apt-get -y -qq $apt_opts"
# Seeding is opportunistic, so it retries once instead of four times: a
# throttled mirror then costs about fifteen seconds before the job installs
# online, not the whole cap.
seed_opts="-o Acquire::Retries=1 -o Acquire::http::Timeout=10 -o Acquire::https::Timeout=10"
apt_get_seed="apt-get -y -qq $seed_opts"
cache=${MAJADU_RUNTIME_DEPS_CACHE:-}

# 0. Nothing to do: every pinned package is on disk and there is no cache to
#    seed. Reaching a mirror here would only re-resolve a set that is already
#    resolved.
if [ -z "$missing" ] &&
  { [ -z "$cache" ] || [ -z "$(find "$cache" -maxdepth 1 -name '*.deb' -print -quit 2>/dev/null)" ]; }; then
  printf 'runtime-deps: all %s packages already installed\n' "$total"
  exit 0
fi

# `timeout` exits 124 when the cap is what stopped the command; any other code
# is apt's own failure and is reported as that.
run_apt() {
  _step=$1
  shift
  _code=0
  # shellcheck disable=SC2086 # option lists on purpose
  timeout "$budget" "$@" || _code=$?
  [ "$_code" -eq 0 ] && return 0
  if [ "$_code" -eq 124 ]; then
    fail "$_step did not finish in ${budget}s; the mirror is too slow for this step. Raise MAJADU_RUNTIME_DEPS_TIMEOUT, or let a run seed MAJADU_RUNTIME_DEPS_CACHE so later runs install from disk"
  fi
  fail "$_step failed with exit $_code (apt output above); the pinned packages were: $(printf '%s' "$packages" | tr '\n' ' ')"
}

# The same cap, but a miss is not fatal: `try_apt` is for steps that only save
# time later. On a cold run every job seeds the same cache key at once, the
# mirror throttles the burst, and failing the job there would turn a cache that
# was supposed to be an optimisation into a hard dependency. PR #82 paid that:
# five jobs of one run died on the 180s cap while the mirror was answering
# other jobs normally.
try_apt() {
  _step=$1
  shift
  _code=0
  # shellcheck disable=SC2086 # option lists on purpose
  timeout "$budget" "$@" || _code=$?
  [ "$_code" -eq 0 ] && return 0
  if [ "$_code" -eq 124 ]; then
    printf 'runtime-deps: %s hit the %ss cap; leaving the cache alone and installing online\n' "$_step" "$budget"
  else
    printf 'runtime-deps: %s failed with exit %s; leaving the cache alone and installing online\n' "$_step" "$_code"
  fi
  return 1
}

# 1. A cache hit installs from disk. `--no-download` refuses to reach a mirror;
#    when the cached set cannot satisfy the current lists apt exits fast and we
#    fall through instead of failing the job.
if [ -n "$cache" ] &&
  [ -n "$(find "$cache" -maxdepth 1 -name '*.deb' -print -quit 2>/dev/null)" ]; then
  printf 'runtime-deps: trying the cached .deb set in %s\n' "$cache"
  if timeout "$budget" sudo $apt_get \
    -o Dir::Cache::archives="$cache" --no-download install $packages; then
    printf 'runtime-deps: ok (%s packages installed from cache)\n' "$total"
    exit 0
  fi
  printf 'runtime-deps: the cached set did not satisfy apt; falling back to a bounded online install\n'
fi

# 2. The online path. `apt-get update` is only paid when the cache could not
#    answer, and the download step fills the cache for next time. Seeding stays
#    best effort: a capped or failed download drops the partial .deb set and the
#    job still installs online below, because the cache is an optimisation and
#    never a prerequisite for the job to pass.
run_apt "apt-get update" sudo apt-get update -qq $apt_opts

installed=0
if [ -n "$cache" ]; then
  mkdir -p "$cache"
  # apt downloads as `_apt`, which cannot write into a 0700 runner directory;
  # without this it falls back to an unsandboxed root download or stays silent.
  chmod 0777 "$cache" 2>/dev/null || true
  printf 'runtime-deps: seeding the .deb cache in %s\n' "$cache"
  # shellcheck disable=SC2086 # option lists on purpose
  if try_apt "downloading the runtime package set" \
      sudo $apt_get_seed -o Dir::Cache::archives="$cache" install --download-only $packages &&
    # shellcheck disable=SC2086 # option lists on purpose
    try_apt "installing the runtime package set from the seeded cache" \
      sudo $apt_get -o Dir::Cache::archives="$cache" --no-download install $packages; then
    installed=1
  else
    # A half-filled cache is worse than none: apt would treat the set as met and
    # then fail on the .deb that never arrived.
    find "$cache" -maxdepth 1 -name '*.deb' -delete 2>/dev/null || true
  fi
fi

if [ "$installed" -eq 0 ]; then
  run_apt "installing the runtime package set" sudo $apt_get install $packages
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
printf 'runtime-deps: ok (%s packages installed)\n' "$total"
