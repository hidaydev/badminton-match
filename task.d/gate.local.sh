#!/usr/bin/env sh
# badminton static checks for `./task gate`: the generated-file fingerprint and the quoted
# counts. Neither installs anything; both compile a small Nim tool, so they need the toolchain
# that CI installs and a laptop with Nim already has. The golden CI/CD contract, the shell
# syntax pass and the secret scan are `task.d/gate.sh` itself, not repeated here.
set -eu
cd "$(dirname "$0")/.."

if ! command -v nim >/dev/null 2>&1; then
  printf '   nim not on PATH: static checks skipped here (CI runs them)\n'
  exit 0
fi

sh ./task contract-check
sh ./task docs-check
