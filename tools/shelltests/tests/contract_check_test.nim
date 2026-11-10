# SEC-10: `./task contract-check` has to stop on the access-table gate, not
# only on the fingerprint. The gate itself is a Nim program and cannot run under
# the fixture's fake compiler, so these cases prove the wiring: a red
# `contract-keys` makes the target red and its message reaches the log.

import std/[os, strutils, unittest]
import ../harness

const gateNim = """#!/bin/sh
out=
source=
for arg in "$@"; do
  case "$arg" in
    -o:*) out=${arg#-o:} ;;
    *contract-keys/main.nim) source=keys ;;
  esac
done
mkdir -p "$(dirname "$out")"
if [ "$source" = keys ]; then
  printf '#!/bin/sh\nprintf "contract-keys: 1 problem(s)\\n  patchPlayer (PATCH /c/{slug}/players/{playerId}): no row in testdata/authz/matrix.yaml\\n" >&2\nexit 1\n' >"$out"
else
  printf '#!/bin/sh\nexit 0\n' >"$out"
fi
chmod +x "$out"
exit 0
"""

suite "contract-check wiring":
  test "a green access-table gate leaves the target green":
    let fixture = newFixture("contract-check-ok")
    defer: removeDir(fixture.root)
    let result = fixture.runTask(@["contract-check"])
    check result.exitCode == 0

  test "a red access-table gate fails the target and names the operation":
    let fixture = newFixture("contract-check-red")
    defer: removeDir(fixture.root)
    discard fixture.installFake("nim", gateNim)
    let result = fixture.runTask(@["contract-check"])
    check result.exitCode == 1
    check result.stderr.contains("contract-keys: 1 problem(s)")
    check result.stderr.contains("patchPlayer")
    check result.stderr.contains("no row in testdata/authz/matrix.yaml")
