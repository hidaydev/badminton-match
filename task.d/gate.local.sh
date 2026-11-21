#!/usr/bin/env sh
# badminton static checks for `./task gate`: the generated-file fingerprint and the quoted
# counts. Neither installs anything; both compile a small Nim tool, so they need the toolchain
# that CI installs and a laptop with Nim already has. The golden CI/CD contract, the shell
# syntax pass and the secret scan are `task.d/gate.sh` itself, not repeated here.
set -eu
cd "$(dirname "$0")/.."

if ! command -v nim >/dev/null 2>&1; then
  # REL-QA-06: a hook that reports green because it did not run is a gate that
  # passes on a machine which cannot check anything. `./task gate --no-hook` is
  # the documented way to skip the hook, and gate.sh already honours it by not
  # calling this file.
  printf 'error: nim not on PATH, so the static checks cannot run; install the toolchain or run ./task gate --no-hook\n' >&2
  exit 1
fi

sh ./task contract-check
sh ./task docs-check
