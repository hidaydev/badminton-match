import std/[algorithm, os, strutils, unittest]
import ../harness

proc touch(path: string) =
  createDir(path.parentDir)
  writeFile(path, "")

suite "lib.sh guards":
  test "refuses to load without each required environment variable":
    let fixture = newFixture("lib-env")
    defer: removeDir(fixture.root)
    for name in ["REPO_ROOT", "WORKTREE", "NIMCACHE_CHECK", "NIMCACHE_BUILD"]:
      let result = fixture.runLib(". \"$1\"", unsetEnv = @[name])
      check result.exitCode != 0
      check result.stderr.contains(name & " is not set")

  test "fail writes the error and exits 1":
    let fixture = newFixture("lib-fail")
    defer: removeDir(fixture.root)
    let result = fixture.runLib(". \"$1\"; fail \"boom: detail\"")
    check result.exitCode == 1
    check result.stderr == "error: boom: detail\n"
    check result.stdout.len == 0

  test "require_cmd rejects a missing command":
    let fixture = newFixture("lib-require")
    defer: removeDir(fixture.root)
    let missing = fixture.runLib(". \"$1\"; require_cmd tl18_missing_cmd")
    check missing.exitCode == 1
    check missing.stderr.contains("required command not found: tl18_missing_cmd")
    let present = fixture.runLib(". \"$1\"; require_cmd sh; printf 'ok\\n'")
    check present.exitCode == 0
    check present.stdout == "ok\n"

  test "junit_finish writes one testcase per suite and marks failures and skips":
    let fixture = newFixture("lib-junit")
    defer: removeDir(fixture.root)
    let result = fixture.runLib(""". "$1"
junit_begin
junit_record "modules/alpha/tests/alpha_test.nim" 0 1234
junit_record "tools/import/tests/import_test.nim" 77 10
junit_record "apps/api/tests/broken_test.nim" 1 500
junit_finish""")
    check result.exitCode == 0
    let report = readFile(
      fixture.root / ".cache" / "tl18-wt" / "junit" / "junit.xml")
    check report.contains("tests=\"3\"")
    check report.contains("failures=\"1\"")
    check report.contains("skipped=\"1\"")
    # QA-20: the duration travels with the result, so slow-test drift is visible
    # in the uploaded report instead of being lost with the console log.
    check report.contains("time=\"1.744\"")
    check report.contains(
      "<testcase name=\"modules/alpha/tests/alpha_test.nim\" time=\"1.234\"/>")
    check report.contains(
      "<testcase name=\"tools/import/tests/import_test.nim\" time=\"0.010\"><skipped/></testcase>")
    check report.contains(
      "<testcase name=\"apps/api/tests/broken_test.nim\" time=\"0.500\"><failure message=\"exit 1\"/></testcase>")

  test "list_test_files hides integration suites unless INTEGRATION=1":
    let fixture = newFixture("lib-list")
    defer: removeDir(fixture.root)
    let unitOnly = [
      "apps/api/tests/api_test.nim",
      "modules/alpha/tests/alpha_test.nim",
      "shared/platform/tests/shared_test.nim",
    ]
    let integration = [
      "modules/alpha/tests/integration/alpha_db_test.nim",
      "tools/widget/tests/integration/widget_test.nim",
    ]
    for relative in unitOnly:
      touch(fixture.root / relative)
    for relative in integration:
      touch(fixture.root / relative)
    touch(fixture.root / "modules/alpha/tests/helper.nim")

    let defaultRun = fixture.runLib(". \"$1\"; set +e; list_test_files; printf 'END'")
    check defaultRun.exitCode == 0
    var expectedUnit: seq[string]
    for relative in unitOnly:
      expectedUnit.add(fixture.root / relative)
    expectedUnit.sort()
    check defaultRun.stdout == expectedUnit.join("\n") & "\nEND"

    let explicitOff = fixture.runLib(". \"$1\"; set +e; list_test_files; printf 'END'",
      extraEnv = @[("INTEGRATION", "0")])
    check explicitOff.stdout == defaultRun.stdout

    let withIntegration = fixture.runLib(". \"$1\"; set +e; list_test_files; printf 'END'",
      extraEnv = @[("INTEGRATION", "1")])
    var expectedAll = expectedUnit
    for relative in integration:
      expectedAll.add(fixture.root / relative)
    expectedAll.sort()
    check withIntegration.exitCode == 0
    check withIntegration.stdout == expectedAll.join("\n") & "\nEND"