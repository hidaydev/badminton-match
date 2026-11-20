import std/[os, strutils, unittest]
import ../harness

# QA-22: the required check is the repository setting, not the document, and
# `Gate` is the only one: it aggregates every in-repo job. The instrumented
# coverage graph that used to report separately was removed on 2026-11-20, so a
# setting that still requires it would block every pull request.

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
  test "the required Gate check passes":
    let fixture = newFixture("protection-ok")
    defer: removeDir(fixture.root)
    fixture.prepare("Gate")
    let result = fixture.runTask(@["branch-protection"],
      extraEnv = @[("FAKE_CONTEXTS", "Gate")])
    check result.exitCode == 0
    check result.stdout.contains("requires Gate")
    check result.stdout.contains("branch-protection: ok")

  test "a missing Gate fails and names it":
    let fixture = newFixture("protection-gate")
    defer: removeDir(fixture.root)
    fixture.prepare("")
    let result = fixture.runTask(@["branch-protection"],
      extraEnv = @[("FAKE_CONTEXTS", "")])
    check result.exitCode == 1
    check result.stderr.contains("does not require Gate")

  test "an unauthenticated gh fails with the command that fixes it":
    let fixture = newFixture("protection-auth")
    defer: removeDir(fixture.root)
    fixture.prepare("", authOk = false)
    let result = fixture.runTask(@["branch-protection"])
    check result.exitCode == 1
    check result.stderr.contains("gh auth login")
