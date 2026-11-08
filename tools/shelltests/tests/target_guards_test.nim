import std/[os, strutils, unittest]
import ../harness

proc touch(path: string) =
  createDir(path.parentDir)
  writeFile(path, "")

suite "task target guards":
  test "test.sh refuses an empty MAJADU_PG_DSN":
    let fixture = newFixture("test-empty-dsn")
    defer: removeDir(fixture.root)
    let result = fixture.runTask(@["test"], extraEnv = @[("MAJADU_PG_DSN", "")])
    check result.exitCode == 1
    check result.stderr.contains("MAJADU_PG_DSN is empty")

  test "test.sh refuses a database name without test":
    let fixture = newFixture("test-bad-dsn")
    defer: removeDir(fixture.root)
    let result = fixture.runTask(@["test"],
      extraEnv = @[("MAJADU_PG_DSN", "postgresql://user@127.0.0.1:5432/bm2")])
    check result.exitCode == 1
    check result.stderr.contains("refusing database 'bm2'")

  test "test.sh runs when ALLOW_SHARED_DB=1":
    let fixture = newFixture("test-shared-db")
    defer: removeDir(fixture.root)
    let result = fixture.runTask(@["test"], extraEnv = @[
      ("MAJADU_PG_DSN", "postgresql://user@127.0.0.1:5432/bm2"),
      ("ALLOW_SHARED_DB", "1"),
    ])
    check result.exitCode == 0
    check result.stdout.contains("test: ok")
    check result.stdout.contains("skips: 0 skipped")

  test "check.sh rejects an unknown argument":
    let fixture = newFixture("check-arg")
    defer: removeDir(fixture.root)
    let result = fixture.runTask(@["check", "bogus"])
    check result.exitCode == 1
    check result.stderr.contains("usage: ./task check [--no-run]")

  test "check.sh accepts --no-run":
    let fixture = newFixture("check-no-run")
    defer: removeDir(fixture.root)
    let result = fixture.runTask(@["check", "--no-run"])
    check result.exitCode == 0
    check result.stdout.contains("check: ok (unit suites compiled, not run")

  test "verify.sh refuses a module with no tests directory":
    let fixture = newFixture("verify-missing")
    defer: removeDir(fixture.root)
    let result = fixture.runTask(@["verify", "nosuchmodule"])
    check result.exitCode == 1
    check result.stderr.contains("no tests directory for module: nosuchmodule")

  test "verify.sh refuses an integration directory without a DSN":
    let fixture = newFixture("verify-integration")
    defer: removeDir(fixture.root)
    touch(fixture.root / "modules" / "widgeted" / "tests" / "integration" / "widget_test.nim")
    let result = fixture.runTask(@["verify", "widgeted"])
    check result.exitCode == 1
    check result.stderr.contains("MAJADU_PG_DSN is required for integration tests in widgeted")

  test "verify.sh names INTEGRATION=1 when the DSN is missing":
    let fixture = newFixture("verify-integration-flag")
    defer: removeDir(fixture.root)
    touch(fixture.root / "modules" / "widgeted" / "tests" / "integration" / "widget_test.nim")
    let result = fixture.runTask(@["verify", "widgeted"],
      extraEnv = @[("INTEGRATION", "1")])
    check result.exitCode == 1
    check result.stderr.contains("INTEGRATION=1 needs MAJADU_PG_DSN to run the widgeted suites")

  test "verify.sh runs a unit-only module without a DSN":
    let fixture = newFixture("verify-unit")
    defer: removeDir(fixture.root)
    touch(fixture.root / "modules" / "unitonly" / "tests" / "unit_test.nim")
    let result = fixture.runTask(@["verify", "unitonly"])
    check result.exitCode == 0
    check result.stdout.contains("verify: unitonly ok")

  test "audit-retention.sh refuses the application DSN as its own":
    let fixture = newFixture("audit-same-dsn")
    defer: removeDir(fixture.root)
    let dsn = "postgresql://owner@127.0.0.1:5432/bm2"
    let result = fixture.runTask(@["audit-retention"],
      extraEnv = @[("MAJADU_AUDIT_DSN", dsn), ("MAJADU_PG_DSN", dsn)])
    check result.exitCode == 1
    check result.stderr.contains("MAJADU_AUDIT_DSN must differ from MAJADU_PG_DSN")

  test "audit-retention.sh requires MAJADU_AUDIT_DSN":
    let fixture = newFixture("audit-missing-dsn")
    defer: removeDir(fixture.root)
    let result = fixture.runTask(@["audit-retention"])
    check result.exitCode != 0
    check result.stderr.contains("MAJADU_AUDIT_DSN is required")