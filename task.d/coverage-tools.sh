#!/bin/sh
# lcov 2.6 and gcovr 8.8, the two tools `deps.lock` pins, installed once per
# cache key instead of once per job and per shard.
#
# apt on the runner ships lcov 2.0 and gcovr 7.0, and a report written by 2.0
# and merged by 2.6 is not the same measurement the baseline was recorded with,
# so both come from upstream. That install was inline in four jobs and it was
# the setup half of every coverage shard: 94s in shard 4 on main 44478153535,
# 42s in `E2E: browser`, and 48 to 162s across the shards of a run. Almost all
# of it was `apt-get update` and pip resolving against the network, not the lcov
# build itself.
#
# The Perl modules lcov loads at startup are apt packages and come from
# `./task runtime-deps`, so this script only fetches what pip and git would
# otherwise re-resolve:
#
# 1. The lcov source tree is cached under MAJADU_COVERAGE_TOOLS_CACHE and
#    installed from there, so a warm run copies files instead of cloning.
# 2. gcovr is cached as a wheel set and installed with `--no-index`, so a warm
#    run never opens the network.
# 3. Both versions are re-read after installing and a mismatch fails the step.
#    "make install exited 0" is not proof that `lcov --version` says 2.6, and
#    `./task deps-check` would be the one to catch it much later.
set -eu

# `./task coverage-tools` provides REPO_ROOT and the shared helpers.
. "$(dirname "$0")/lib.sh"

want_lcov=2.6
want_gcovr=8.8
cache=${MAJADU_COVERAGE_TOOLS_CACHE:-$REPO_ROOT/.cache/coverage-tools}
tree="$cache/lcov-$want_lcov"
wheels="$cache/wheels"

# The pins describe the Linux measurement; another platform records its own
# baseline with its own toolchain.
if [ "$(uname -s)" != "Linux" ]; then
  printf 'coverage-tools: not Linux, nothing to install\n'
  exit 0
fi

read_lcov_version() {
  lcov --version 2>/dev/null |
    sed -n -e 's/.*LCOV version \([0-9][0-9.]*\).*/\1/p' |
    head -1
}

read_gcovr_version() {
  gcovr --version 2>/dev/null | sed -n -e '1s/^gcovr \([0-9][0-9.]*\).*/\1/p'
}

have_lcov=$(read_lcov_version)
have_gcovr=$(read_gcovr_version)

if [ "$have_lcov" = "$want_lcov" ] && [ "$have_gcovr" = "$want_gcovr" ]; then
  printf 'coverage-tools: lcov %s and gcovr %s already installed\n' \
    "$want_lcov" "$want_gcovr"
  exit 0
fi

if [ "$have_lcov" != "$want_lcov" ]; then
  if [ ! -f "$tree/Makefile" ]; then
    rm -rf "$tree" "$tree.clone"
    printf 'coverage-tools: cloning lcov v%s into %s\n' "$want_lcov" "$tree"
    mkdir -p "$cache"
    git clone --depth 1 --branch "v$want_lcov" \
      https://github.com/linux-test-project/lcov "$tree.clone"
    mv "$tree.clone" "$tree"
  fi
  # LCOV_NO_XS=1 skips the XS modules, which need a C++20 build and contribute
  # nothing to `lcov --version`; the pure Perl modules are installed above.
  sudo make -C "$tree" install LCOV_NO_DOC=1 LCOV_NO_XS=1 >/dev/null
fi

if [ "$have_gcovr" != "$want_gcovr" ]; then
  mkdir -p "$wheels"
  if ! ls "$wheels"/gcovr-*.whl >/dev/null 2>&1; then
    printf 'coverage-tools: caching the gcovr %s wheel set in %s\n' "$want_gcovr" "$wheels"
    python3 -m pip download "gcovr==$want_gcovr" -d "$wheels" >/dev/null
  fi
  # A cached set that pip cannot satisfy falls back to the network rather than
  # failing the job; the offline path is the common one, not the only one.
  if ! python3 -m pip install --break-system-packages --no-index \
    --find-links "$wheels" "gcovr==$want_gcovr" >/dev/null 2>&1; then
    printf 'coverage-tools: the cached wheel set did not satisfy pip; installing online\n'
    python3 -m pip install --break-system-packages "gcovr==$want_gcovr" >/dev/null
  fi
fi

# The versions the rest of the run will use, read back from the binaries. A
# mismatch here is the only thing that proves the install did not take.
have_lcov=$(read_lcov_version)
have_gcovr=$(read_gcovr_version)
if [ "$have_lcov" != "$want_lcov" ] || [ "$have_gcovr" != "$want_gcovr" ]; then
  fail "deps.lock pins lcov $want_lcov and gcovr $want_gcovr, the installed binaries report lcov '${have_lcov:-none}' and gcovr '${have_gcovr:-none}'"
fi

printf 'coverage-tools: ok (lcov %s, gcovr %s)\n' "$have_lcov" "$have_gcovr"
