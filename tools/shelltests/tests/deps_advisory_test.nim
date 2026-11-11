# SEC-05: a content digest proves the pinned bytes did not change, never that they
# are safe to run. OSV has no Nimble ecosystem, so the only matchable subject is
# the commit the package is pinned to, and that query is the verification step.
#
# These cases fix the block in both directions: a recorded `none` that OSV no
# longer agrees with fails, and a pin with no recorded verdict fails, so the lock
# cannot quietly stop describing the universe it claims to describe. The query
# itself is a live service, so the fixture supplies a fake `curl` that writes a
# body and reports a status code the case under test chooses.

import std/[os, strutils, unittest]
import ../harness

const
  commit = "77a7563e87a1045e4e407a3a68731e299fa3507e"
  otherCommit = "0000000000000000000000000000000000000000"
  entryName = "mummy"

const fakeCurl = """#!/bin/sh
out=
want=0
for arg in "$@"; do
  if [ "$want" = 1 ]; then out=$arg; want=0; continue; fi
  if [ "$arg" = "-o" ]; then want=1; fi
done
body=${FAKE_OSV_BODY-}
[ -n "$body" ] || body='{}'
if [ -n "$out" ]; then printf '%s' "$body" >"$out"; fi
printf '%s' "${FAKE_OSV_CODE:-200}"
"""

const advisoryJson = """{"results":[{"vulns":[{"id":"GHSA-aaaa-bbbb-cccc"}]}]}"""

proc seedPackage(fixture: Fixture) =
  ## One installed package at the pinned commit, so `nimble:` resolves the way it
  ## does on a warm runner, plus the placeholder lock `--print` reads.
  let dir = fixture.root / "home" / ".nimble" / "pkgs2" /
    (entryName & "-0.4.8-" & commit)
  createDir(dir)
  writeFile(dir / "mummy.nim", "# package\n")
  writeFile(dir / "nimblemeta.json",
    "{\n  \"version\": \"0.4.8\",\n  \"vcsRevision\": \"" & commit & "\"\n}\n")
  fixture.installFake("curl", fakeCurl)
  writeFile(fixture.root / "deps.lock",
    "tree " & "0".repeat(64) & "\n" &
    "mummy 0.4.8 nimble:https://github.com/guzba/mummy@" & commit & " -\n")

proc freeze(fixture: Fixture, advisory: string) =
  ## `--print` supplies the entry digest and the tree, so each case varies only
  ## the advisory line it is about.
  let printed = fixture.runTask(@["deps-check", "--print"])
  var lines: seq[string] = @[]
  for line in printed.stdout.splitLines:
    if line.startsWith("tree ") or line.startsWith(entryName & " "):
      lines.add(line)
  if advisory.len > 0:
    lines.add(advisory)
  writeFile(fixture.root / "deps.lock", lines.join("\n") & "\n")

proc clean(fixture: Fixture, advisory = "") =
  fixture.seedPackage()
  fixture.freeze(if advisory.len > 0: advisory else:
    "advisory nim:" & entryName & " " & commit & " none")

suite "deps-check advisory universe":
  test "a recorded clean verdict passes":
    let fixture = newFixture("deps-advisory-ok")
    defer: removeDir(fixture.root)
    fixture.clean()
    let result = fixture.runTask(@["deps-check"])
    check result.exitCode == 0
    check result.stdout.contains("deps-check: ok")

  test "a new advisory on a pinned commit fails":
    let fixture = newFixture("deps-advisory-drift")
    defer: removeDir(fixture.root)
    fixture.seedPackage()
    fixture.freeze("advisory nim:" & entryName & " " & commit & " none")
    let result = fixture.runTask(@["deps-check"],
      extraEnv = @[("FAKE_OSV_BODY", advisoryJson)])
    check result.exitCode == 1
    check result.stderr.contains("OSV now answers 'GHSA-aaaa-bbbb-cccc'")

  test "a pinned package with no recorded verdict fails":
    let fixture = newFixture("deps-advisory-missing")
    defer: removeDir(fixture.root)
    fixture.seedPackage()
    fixture.freeze("")
    let result = fixture.runTask(@["deps-check"])
    check result.exitCode == 1
    check result.stderr.contains("with no recorded verdict")

  test "a verdict recorded against another commit fails":
    let fixture = newFixture("deps-advisory-stale")
    defer: removeDir(fixture.root)
    fixture.clean("advisory nim:" & entryName & " " & otherCommit & " none")
    let result = fixture.runTask(@["deps-check"])
    check result.exitCode == 1
    check result.stderr.contains("re-query the new pin")

  test "a verdict for a package the lock no longer pins fails":
    let fixture = newFixture("deps-advisory-orphan")
    defer: removeDir(fixture.root)
    fixture.clean("advisory nim:webby " & commit & " none")
    let result = fixture.runTask(@["deps-check"])
    check result.exitCode == 1
    check result.stderr.contains("no pinned nimble entry")

  test "an unreachable OSV is a skip, not a pass":
    let fixture = newFixture("deps-advisory-offline")
    defer: removeDir(fixture.root)
    fixture.clean()
    let result = fixture.runTask(@["deps-check"],
      extraEnv = @[("FAKE_OSV_CODE", "000")])
    check result.exitCode == 0
    check result.stderr.contains("could not be queried")

  test "skipping the block says so instead of proving nothing":
    let fixture = newFixture("deps-advisory-skip")
    defer: removeDir(fixture.root)
    fixture.clean()
    let result = fixture.runTask(@["deps-check", "--skip", "advisory"])
    check result.exitCode == 0
    check result.stderr.contains("advisory universe not checked: skipped")
