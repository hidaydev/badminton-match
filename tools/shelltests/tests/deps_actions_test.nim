import std/[os, strutils, unittest]
import ../harness

# QA-15: a 40-hex pin is not the same thing as a commit that exists. The
# coverage workflow once named a commit GitHub could not resolve and failed at
# setup, before any test ran. `./task deps-check` now asks GitHub.

const emptyTree = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
const sha = "55cc8345863c7cc4c66a329aec7e433d2d1c52a9"

proc prepare(fixture: Fixture, code: string) =
  writeFile(fixture.root / "deps.lock", "tree " & emptyTree & "\n")
  createDir(fixture.root / ".github" / "workflows")
  writeFile(fixture.root / ".github" / "workflows" / "ci.yml",
    "steps:\n  - uses: actions/cache@" & sha & " # v6.1.0\n")
  fixture.installFake("curl",
    "#!/bin/sh\nprintf '%s' \"${FAKE_CURL_CODE:-200}\"\n")

suite "deps-check action pins":
  test "a pin GitHub resolves passes":
    let fixture = newFixture("deps-action-ok")
    defer: removeDir(fixture.root)
    fixture.prepare("200")
    let result = fixture.runTask(@["deps-check"],
      extraEnv = @[("FAKE_CURL_CODE", "200")])
    check result.exitCode == 0
    check result.stdout.contains("deps-check: ok")

  test "a pin GitHub cannot resolve fails":
    let fixture = newFixture("deps-action-404")
    defer: removeDir(fixture.root)
    fixture.prepare("404")
    let result = fixture.runTask(@["deps-check"],
      extraEnv = @[("FAKE_CURL_CODE", "404")])
    check result.exitCode == 1
    check result.stderr.contains("does not resolve on GitHub")

  test "an offline run reports a skip instead of inventing a verdict":
    let fixture = newFixture("deps-action-offline")
    defer: removeDir(fixture.root)
    fixture.prepare("000")
    let result = fixture.runTask(@["deps-check"],
      extraEnv = @[("FAKE_CURL_CODE", "000")])
    check result.exitCode == 0
    check result.stderr.contains("shape was checked")
