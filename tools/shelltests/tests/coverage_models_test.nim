import std/[os, strutils, unittest]
import ../harness

# QA-12: the coverage gate decides pass or fail for every pull request, and its
# own rules were only ever exercised by hand. Each model under
# `task.d/fixtures/coverage/` is one rule with a documented verdict in its
# README; this suite runs them through `./task coverage --model`, which costs
# seconds and touches no database.

proc model(name: string): string =
  "task.d/fixtures/coverage/" & name

suite "coverage gate models":
  test "a clean model passes":
    let fixture = newFixture("coverage-passing")
    defer: removeDir(fixture.root)
    let result = fixture.runTask(@["coverage", "--model", model("passing")])
    check result.exitCode == 0
    check result.stdout.contains("coverage: ok (per-file ratchet held)")

  test "a new file at zero percent fails even when the totals rose":
    let fixture = newFixture("coverage-new-zero")
    defer: removeDir(fixture.root)
    let result = fixture.runTask(@["coverage", "--model", model("new-zero-file")])
    check result.exitCode == 1
    check result.stderr.contains("has 0 of")

  test "one file dropping while its domain stays flat fails":
    let fixture = newFixture("coverage-file-decrease")
    defer: removeDir(fixture.root)
    let result = fixture.runTask(@["coverage", "--model", model("file-decrease")])
    check result.exitCode == 1
    check result.stderr.contains("modules/beta/domain/a.nim dropped from 90.00% to 80.00%")

  test "a drop hidden behind a rising domain still fails":
    let fixture = newFixture("coverage-domain-hides")
    defer: removeDir(fixture.root)
    let result = fixture.runTask(@["coverage", "--model", model("domain-hides-file")])
    check result.exitCode == 1
    check result.stderr.contains("dropped")

  test "diff coverage below 90 percent fails a passing ratchet":
    let fixture = newFixture("coverage-diff")
    defer: removeDir(fixture.root)
    let result = fixture.runTask(@["coverage", "--model", model("diff-below-90")])
    check result.exitCode == 1
    check result.stderr.contains("diff coverage 50.00%")

  test "update refuses a decrease without the flag":
    let fixture = newFixture("coverage-update-refuse")
    defer: removeDir(fixture.root)
    let result = fixture.runTask(@["coverage", "--model", model("file-decrease"),
      "--update"])
    check result.exitCode == 1
    check result.stderr.contains("refusing decrease")

  test "update accepts the same decrease when the flag is passed":
    let fixture = newFixture("coverage-update-allow")
    defer: removeDir(fixture.root)
    let result = fixture.runTask(@["coverage", "--model", model("file-decrease"),
      "--update", "--allow-decrease"])
    check result.exitCode == 0
    check result.stderr.contains("accepting decrease")
    # A model is never rewritten, so the checked-in verdict is stable.
    let baseline = fixture.root / model("file-decrease") / "baseline.json"
    check readFile(baseline).contains("\"floor\"")
