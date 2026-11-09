import std/[os, strutils, unittest]
import ../harness

# QA-22: "Gate" and "Coverage: ratchet" are two workflows, and GitHub cannot
# express a cross-workflow dependency. The repository setting is therefore part
# of the gate, and this target checks the setting rather than the document.

const fakeGh = """#!/bin/sh
case "$1" in
  auth) exit 0 ;;
  repo) printf 'owner/repo\n' ;;
  api) printf '%s\n' "$FAKE_CONTEXTS" ;;
  *) exit 1 ;;
esac
"""

proc prepare(fixture: Fixture, contexts: string, authOk = true) =
  let body = if authOk: fakeGh else: "#!/bin/sh\nexit 1\n"
  fixture.installFake("gh", body)
  writeFile(fixture.root / ".contexts", contexts)

suite "branch protection":
  test "both required checks present passes":
    let fixture = newFixture("protection-ok")
    defer: removeDir(fixture.root)
    fixture.prepare("Gate\nCoverage: ratchet")
    let result = fixture.runTask(@["branch-protection"],
      extraEnv = @[("FAKE_CONTEXTS", "Gate\nCoverage: ratchet")])
    check result.exitCode == 0
    check result.stdout.contains("requires Coverage: ratchet")
    check result.stdout.contains("branch-protection: ok")

  test "a missing coverage check fails and names it":
    let fixture = newFixture("protection-coverage")
    defer: removeDir(fixture.root)
    fixture.prepare("Gate")
    let result = fixture.runTask(@["branch-protection"],
      extraEnv = @[("FAKE_CONTEXTS", "Gate")])
    check result.exitCode == 1
    check result.stderr.contains("does not require Coverage: ratchet")

  test "an unauthenticated gh fails with the command that fixes it":
    let fixture = newFixture("protection-auth")
    defer: removeDir(fixture.root)
    fixture.prepare("", authOk = false)
    let result = fixture.runTask(@["branch-protection"])
    check result.exitCode == 1
    check result.stderr.contains("gh auth login")
