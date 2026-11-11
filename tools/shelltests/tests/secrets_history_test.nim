# GITLEAKS: the full-history scan must turn three outcomes into three
# different ones. A finding fails, a clean scan passes, and a scanner that did
# not reach a verdict fails too: an inconclusive exit read as clean is exactly
# how a gate stops being one.
#
# The scanner is a release asset that a laptop does not have, so the fixture
# supplies a fake `gitleaks` that records the arguments it was called with and
# exits with the code the case chooses.

import std/[os, strutils, unittest]
import ../harness

const fakeGitleaks = """#!/bin/sh
printf '%s\n' "$@" >"$GITLEAKS_ARGS"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --report-path) shift; printf '[]' >"$1" ;;
  esac
  shift
done
printf '%s\n' "${FAKE_GITLEAKS_OUT:-}"
exit "${FAKE_GITLEAKS_CODE:-0}"
"""

proc prepare(fixture: Fixture) =
  writeFile(fixture.root / ".gitleaks.toml", "[extend]\nuseDefault = true\n")
  fixture.installFake("gitleaks", fakeGitleaks)
  fixture.installFake("git", "#!/bin/sh\nexit 0\n")

suite "secrets-history":
  test "a clean scan passes and scans every ref":
    let fixture = newFixture("secrets-history-ok")
    defer: removeDir(fixture.root)
    fixture.prepare()
    let result = fixture.runTask(@["secrets-history"],
      extraEnv = @[("GITLEAKS_ARGS", fixture.root / "args.txt")])
    check result.exitCode == 0
    check result.stdout.contains("secrets-history: ok")
    let args = fixture.root / "args.txt"
    check fileExists(args)
    let recorded = readFile(args)
    check recorded.contains("--all --full-history")
    check recorded.contains(".gitleaks.toml")

  test "a finding in the history fails":
    let fixture = newFixture("secrets-history-found")
    defer: removeDir(fixture.root)
    fixture.prepare()
    let result = fixture.runTask(@["secrets-history"],
      extraEnv = @[("GITLEAKS_ARGS", fixture.root / "args.txt"),
        ("FAKE_GITLEAKS_CODE", "1")])
    check result.exitCode == 1
    check result.stderr.contains("a finding exists somewhere in the history")

  test "a scanner that reached no verdict fails instead of passing":
    let fixture = newFixture("secrets-history-broken")
    defer: removeDir(fixture.root)
    fixture.prepare()
    let result = fixture.runTask(@["secrets-history"],
      extraEnv = @[("GITLEAKS_ARGS", fixture.root / "args.txt"),
        ("FAKE_GITLEAKS_CODE", "7")])
    check result.exitCode == 1
    check result.stderr.contains("without a verdict")

  test "a missing repository config is refused before the scan":
    let fixture = newFixture("secrets-history-noconfig")
    defer: removeDir(fixture.root)
    fixture.installFake("gitleaks", fakeGitleaks)
    fixture.installFake("git", "#!/bin/sh\nexit 0\n")
    let result = fixture.runTask(@["secrets-history"],
      extraEnv = @[("GITLEAKS_ARGS", fixture.root / "args.txt")])
    check result.exitCode == 1
    check result.stderr.contains("missing")
