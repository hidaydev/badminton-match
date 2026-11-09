import std/[os, strutils, unittest]
import ../harness

suite "deadcode target":
  test "an unallowlisted dead declaration fails the gate":
    let fixture = newFixture("deadcode-fail")
    defer: removeDir(fixture.root)
    let finding = fixture.root /
      "modules/session/schedule.nim(93, 6) Hint: 'classify' is declared but " &
      "not used [XDeclaredButNotUsed]"
    writeExecutable(fixture.binDir / "nim",
      "#!/bin/sh\nprintf '%s\\n' " & quoteShell(finding) & "\nexit 0\n")
    let result = fixture.runTask(@["deadcode"])
    check result.exitCode == 1
    check result.stderr.contains("deadcode: ")
    check result.stderr.contains("XDeclaredButNotUsed")
    check result.stderr.contains("not in tools/archcheck/allowlist_deadcode.txt")

  test "an allowlisted declaration passes and is still printed":
    let fixture = newFixture("deadcode-allowed")
    defer: removeDir(fixture.root)
    let finding = fixture.root /
      "modules/session/schedule.nim(93, 6) Hint: 'classify' is declared but " &
      "not used [XDeclaredButNotUsed]"
    writeExecutable(fixture.binDir / "nim",
      "#!/bin/sh\nprintf '%s\\n' " & quoteShell(finding) & "\nexit 0\n")
    createDir(fixture.root / "tools" / "archcheck")
    writeFile(fixture.root / "tools" / "archcheck" / "allowlist_deadcode.txt",
      "modules/session/schedule.nim:classify\n")
    let result = fixture.runTask(@["deadcode"])
    check result.exitCode == 0
    check result.stdout.contains(
      "deadcode: allowed modules/session/schedule.nim:classify")
    check result.stderr.len == 0
