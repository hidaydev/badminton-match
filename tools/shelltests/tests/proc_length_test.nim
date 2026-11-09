import std/[os, strutils, unittest]
import ../harness

# SQ-18: the function-length gate is a ratchet on the number of procs over 100
# lines. It has to ignore tests, count only definitions, and fail on growth
# instead of on an absolute threshold the tree cannot meet today.

proc setBaseline(fixture: Fixture, max: int) =
  writeFile(fixture.root / "task.d" / "proc-length-baseline.txt",
    "# test baseline\nmax: " & $max & "\n")

proc writeProc(fixture: Fixture, relative: string, lines: int) =
  ## A definition that occupies exactly `lines` lines: the declaration plus
  ## body lines, all at column 0 or two spaces so the parser sees one range.
  let path = fixture.root / relative
  createDir(path.parentDir)
  var body = "proc big*() =\n"
  for _ in 1 ..< lines:
    body.add("  discard\n")
  writeFile(path, body)

suite "proc length gate":
  test "a tree under the limit prints the count and passes":
    let fixture = newFixture("proclen-pass")
    defer: removeDir(fixture.root)
    fixture.setBaseline(0)
    fixture.writeProc("modules/demo/small.nim", 50)
    let result = fixture.runTask(@["proc-length"])
    check result.exitCode == 0
    check result.stdout.contains("proc-length: 0 proc(s) over 100 lines")

  test "a proc over 100 lines fails and names the file":
    let fixture = newFixture("proclen-grow")
    defer: removeDir(fixture.root)
    fixture.setBaseline(0)
    fixture.writeProc("modules/demo/big.nim", 120)
    let result = fixture.runTask(@["proc-length"])
    check result.exitCode == 1
    check result.stdout.contains("proc-length: 1 proc(s) over 100 lines")
    check result.stderr.contains("modules/demo/big.nim big* 120 lines")

  test "a test file is not production code":
    let fixture = newFixture("proclen-tests")
    defer: removeDir(fixture.root)
    fixture.setBaseline(0)
    fixture.writeProc("modules/demo/tests/big_test.nim", 200)
    let result = fixture.runTask(@["proc-length"])
    check result.exitCode == 0
    check result.stdout.contains("proc-length: 0 proc(s) over 100 lines")

  test "the baseline allows a known long proc":
    let fixture = newFixture("proclen-allowed")
    defer: removeDir(fixture.root)
    fixture.setBaseline(1)
    fixture.writeProc("modules/demo/big.nim", 120)
    let result = fixture.runTask(@["proc-length"])
    check result.exitCode == 0
    check result.stdout.contains("proc-length: 1 proc(s) over 100 lines")

  test "a missing baseline fails instead of passing silently":
    let fixture = newFixture("proclen-missing")
    defer: removeDir(fixture.root)
    removeFile(fixture.root / "task.d" / "proc-length-baseline.txt")
    let result = fixture.runTask(@["proc-length"])
    check result.exitCode == 1
    check result.stderr.contains("missing")
