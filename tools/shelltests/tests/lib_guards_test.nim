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
  test "shard_plan balances by measured cost and keeps every suite once":
    # BM-03 / W8: positional slicing is uncorrelated with cost, so the two shards
    # drifted to 63 % on 2026-11-18. With a cost table the slice is LPT: 300 goes
    # to shard 1, 200 and 100 to shard 2, 50 back to shard 1 (350 vs 300).
    let fixture = newFixture("lib-shard-plan")
    defer: removeDir(fixture.root)
    writeFile(fixture.root / "task.d" / "test-costs.tsv",
      "a\t300\nb\t200\nc\t100\nd\t50\n")
    check fileExists(fixture.root / "task.d" / "test-costs.tsv")
    let body = """. "$1"
printf '%s\n' "$REPO_ROOT/a" "$REPO_ROOT/b" "$REPO_ROOT/c" "$REPO_ROOT/d" |
  shard_plan 2 """
    let first = fixture.runLib(body & "1")
    let second = fixture.runLib(body & "2")
    check first.exitCode == 0
    check first.stdout == fixture.root / "a" & "\n" & fixture.root / "d" & "\n"
    check second.stdout == fixture.root / "b" & "\n" & fixture.root / "c" & "\n"

  test "shard_plan survives gawk, which refuses `default` as a variable name":
    # 2026-11-18: `awk -v default=` is a fatal error under gawk and the runner's
    # awk is gawk, so shard 1/2 planned zero suites there while macOS awk, mawk
    # and busybox all accepted it. Guard the name, not just the split.
    let gawk = findExe("gawk")
    if gawk.len == 0:
      skip()
    else:
      let fixture = newFixture("lib-shard-plan-gawk")
      defer: removeDir(fixture.root)
      writeFile(fixture.root / "task.d" / "test-costs.tsv",
        "a\t300\nb\t200\nc\t100\nd\t50\n")
      # The fixture PATH starts at binDir, so this wrapper is the awk that runs.
      writeExecutable(fixture.binDir / "awk",
        "#!/bin/sh\nexec " & quoteShell(gawk) & " \"$@\"\n")
      let result = fixture.runLib(""". "$1"
printf '%s\n' "$REPO_ROOT/a" "$REPO_ROOT/b" "$REPO_ROOT/c" "$REPO_ROOT/d" |
  shard_plan 2 1""")
      check result.exitCode == 0
      check result.stdout == fixture.root / "a" & "\n" & fixture.root / "d" & "\n"

  test "shard_plan gives an unknown suite the median cost, not zero":
    let fixture = newFixture("lib-shard-plan-unknown")
    defer: removeDir(fixture.root)
    writeFile(fixture.root / "task.d" / "test-costs.tsv",
      "a\t300\nb\t200\nc\t100\nd\t50\n")
    # median of 50, 100, 200, 300 is 100, so `e` costs the same as `c` and the
    # greedy pass must still place it by load instead of treating it as free.
    check fileExists(fixture.root / "task.d" / "test-costs.tsv")
    let result = fixture.runLib(""". "$1"
printf '%s\n' "$REPO_ROOT/a" "$REPO_ROOT/b" "$REPO_ROOT/e" | shard_plan 2 2""")
    check result.exitCode == 0
    check result.stdout == fixture.root / "b" & "\n" & fixture.root / "e" & "\n"
  # REL-QA-09: one hung suite used to eat the whole 15-minute job, and a job
  # cancelled at the cap uploads no junit report, so every result the shard had
  # already produced went with it. The cap is per suite and names itself.
  test "run_deadline reports 124 when the suite outlives SUITE_TIMEOUT_S":
    let fixture = newFixture("lib-deadline")
    defer: removeDir(fixture.root)
    discard fixture.installFake("slowsuite", "#!/bin/sh\nsleep 30\n")
    let result = fixture.runLib(""". "$1"
SUITE_TIMEOUT_S=1
run_deadline "$SUITE_TIMEOUT_S" "$SLOW"
printf 'status=%s\n' "$deadline_status"
""", extraEnv = @[("SLOW", "slowsuite")])
    check result.stdout.contains("status=124")

  test "a suite that hits the deadline is a named timeout, not a bare failure":
    let fixture = newFixture("lib-deadline-name")
    defer: removeDir(fixture.root)
    discard fixture.installFake("slowsuite", "#!/bin/sh\nsleep 30\n")
    let result = fixture.runLib(""". "$1"
mkdir -p "$REPO_ROOT/.cache/$WORKTREE"
SUITE_TIMEOUT_S=1
run_deadline "$SUITE_TIMEOUT_S" "$SLOW"
handle_suite_status "$deadline_status" "apps/api/tests/slow_test.nim"
printf 'reached\n'
""", extraEnv = @[("SLOW", "slowsuite")])
    check result.exitCode == 124
    check result.stderr.contains("timeout 1s: apps/api/tests/slow_test.nim")
    check not result.stdout.contains("reached")
    let failures = readFile(
      fixture.root / ".cache" / "tl18-wt" / "failures.tsv")
    check failures.contains("TIMEOUT\tapps/api/tests/slow_test.nim\t124")

  test "schema_lag_report says the dev database is up to date":
    ## REL-DB-12: the developer has to learn the schema they are reading is the
    ## one in the tree, without `./task dev` stopping to prove it.
    let fixture = newFixture("lib-schema-lag-ok")
    defer: removeDir(fixture.root)
    discard fixture.installFake("dbtools",
      "#!/bin/sh\nprintf 'dbtools: verified 60 file(s)\\n'\nexit 0\n")
    let result = fixture.runLib(""". "$1"
schema_lag_report dbtools db/migrations
printf 'reached\n'
""")
    check result.exitCode == 0
    check result.stdout.contains("dev: schema    up to date with db/migrations")
    check result.stdout.contains("reached")

  test "schema_lag_report names each pending migration and still carries on":
    ## The 24-behind case from the audit row, cut down to three files. The count
    ## and the names both come from `dbtools verify`; the helper only formats
    ## them, and it must not turn a stale database into a failed `./task dev`.
    let fixture = newFixture("lib-schema-lag-behind")
    defer: removeDir(fixture.root)
    discard fixture.installFake("dbtools", """#!/bin/sh
cat >&2 <<'EOF'
dbtools: pending migration: 0033_links_legacy_id
dbtools: pending migration: 0034_etl_grants
dbtools: pending migration: 0035_audit_occurred_index
dbtools: 3 problem(s); database is not at the committed schema
EOF
exit 1
""")
    let result = fixture.runLib(""". "$1"
schema_lag_report dbtools db/migrations
printf 'status=%s\n' "$?"
""")
    check result.exitCode == 0
    check result.stdout.contains("dev: schema    3 migration(s) behind db/migrations")
    check result.stdout.contains("dev:   pending  0033_links_legacy_id")
    check result.stdout.contains("dev:   pending  0035_audit_occurred_index")
    check result.stdout.contains("status=0")

  test "schema_lag_report calls a database it cannot read unknown, not lagging":
    ## A first checkout, or a dropped bm2_dev: `dbtools verify` fails with
    ## something other than a pending migration, and `./task dev` must not
    ## report "0 behind" as if the schema were current, nor stop.
    let fixture = newFixture("lib-schema-lag-unknown")
    defer: removeDir(fixture.root)
    discard fixture.installFake("dbtools",
      """#!/bin/sh
printf 'dbtools: MAJADU_PG_DSN is required\n' >&2
exit 1
""")
    let result = fixture.runLib(""". "$1"
schema_lag_report dbtools db/migrations
printf 'reached\n'
""")
    check result.exitCode == 0
    check result.stdout.contains("dev: schema    unknown (dbtools: MAJADU_PG_DSN is required)")
    check result.stdout.contains("./task dev-db")
    check not result.stdout.contains("migration(s) behind")
    check result.stdout.contains("reached")

  test "run_deadline leaves a suite that finishes inside the cap alone":
    let fixture = newFixture("lib-deadline-fast")
    defer: removeDir(fixture.root)
    let result = fixture.runLib(""". "$1"
SUITE_TIMEOUT_S=30
run_deadline "$SUITE_TIMEOUT_S" sh -c 'exit 0'
printf 'status=%s\n' "$deadline_status"
run_deadline "$SUITE_TIMEOUT_S" sh -c 'exit 3'
printf 'second=%s\n' "$deadline_status"
""")
    check result.stdout == "status=0\nsecond=3\n"

