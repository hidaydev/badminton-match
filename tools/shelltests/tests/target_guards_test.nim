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
    check result.stderr.contains("usage: ./task check [--no-run|--static]")

  test "check.sh accepts --no-run":
    let fixture = newFixture("check-no-run")
    defer: removeDir(fixture.root)
    let result = fixture.runTask(@["check", "--no-run"])
    check result.exitCode == 0
    check result.stdout.contains("check: ok (unit suites compiled, not run")

  test "check.sh --static skips the suites entirely":
    ## QA-27: api-check runs this mode; api-test is the job that compiles.
    let fixture = newFixture("check-static")
    defer: removeDir(fixture.root)
    let result = fixture.runTask(@["check", "--static"])
    check result.exitCode == 0
    check result.stdout.contains("check: ok (static gates only")

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
  test "docs-check refuses a stale migration count":
    let fixture = newFixture("docs-check-stale")
    defer: removeDir(fixture.root)
    createDir(fixture.root / "db" / "migrations")
    writeFile(fixture.root / "db" / "migrations" / "0001_init.sql", "select 1;\n")
    createDir(fixture.root / "packages" / "contracts" / "openapi")
    writeFile(fixture.root / "packages" / "contracts" / "openapi" /
      "CONTRACT.sha256", "operations 2\n")
    writeFile(fixture.root / "README.md",
      "| Schema | 3 migrations |\n| Contract | 2 operations |\n")
    let result = fixture.runTask(@["docs-check"])
    check result.exitCode == 1
    check result.stderr.contains("README.md says 3 migrations")

  test "ci-guards --release rejects an SPA rewrite to the RC API":
    let fixture = newFixture("ci-guards-rc-spa")
    defer: removeDir(fixture.root)
    createDir(fixture.root / "apps" / "web")
    createDir(fixture.root / ".github" / "workflows")
    writeFile(fixture.root / "apps" / "web" / "vercel.json",
      "{\"rewrites\":[{\"source\":\"/api/:path*\",\"destination\":" &
      "\"https://api.qouver.com/majadu-rc/:path*\"}]}\n")
    let normal = fixture.runTask(@["ci-guards"])
    check normal.exitCode == 0
    let release = fixture.runTask(@["ci-guards", "--release"])
    check release.exitCode == 1
    check release.stderr.contains("still rewrites /api to the RC backend")

  test "ci-guards rejects a mutable action tag":
    let fixture = newFixture("ci-guards-tag")
    defer: removeDir(fixture.root)
    createDir(fixture.root / ".github" / "workflows")
    writeFile(fixture.root / ".github" / "workflows" / "bad.yml",
      "steps:\n  - uses: owner/repo@v1\n")
    let result = fixture.runTask(@["ci-guards"])
    check result.exitCode == 1
    check result.stderr.contains("is not pinned to a 40-hex commit SHA")

  test "ci-guards rejects a 41-character action SHA":
    let fixture = newFixture("ci-guards-41")
    defer: removeDir(fixture.root)
    createDir(fixture.root / ".github" / "workflows")
    writeFile(fixture.root / ".github" / "workflows" / "bad.yml",
      "steps:\n  - uses: owner/repo@55cc8345863c7cc4c66c329aec7e433d2d1c52a9a\n")
    let result = fixture.runTask(@["ci-guards"])
    check result.exitCode == 1
    check result.stderr.contains("is not pinned to a 40-hex commit SHA")

  test "deps-check refuses a Dockerfile digest that differs from deps.lock":
    let fixture = newFixture("deps-docker-mismatch")
    defer: removeDir(fixture.root)
    createDir(fixture.root / "apps" / "api")
    writeFile(fixture.root / "apps" / "api" / "Dockerfile",
      "FROM docker.io/nimlang/nim:2.4.0@sha256:" &
      "0000000000000000000000000000000000000000000000000000000000000000\n")
    writeFile(fixture.root / "deps.lock",
      "tree deadbeef\n" &
      "nim-base 2.4.0 docker:docker.io/nimlang/nim:2.4.0 sha256:" &
      "e35e49da9bb8a5d4562f9c4f8afc1945c9cdeb525b2a9b3e76431d0556ac0c8f\n")
    let result = fixture.runTask(@["deps-check"])
    check result.exitCode == 1
    check result.stderr.contains("entry differs: nim-base")

  test "the Caddy handlers carry limits, timeouts and the RC allow-list":
    for name in ["site-v1.caddy", "site-v2.caddy"]:
      let text = readFile(repoDir / "ops" / "caddy" / name)
      check text.contains("max_size 1MB")
      check text.contains("dial_timeout 3s")
      check text.contains("health_uri /readyz")
      check text.contains("handle_response @upstream_error")
    let rc = readFile(repoDir / "ops" / "caddy" / "site-rc.caddy")
    check rc.contains("@internal remote_ip")
    check rc.contains("respond \"Forbidden\" 403")
    check rc.contains("health_uri /readyz")

  test "every workflow that runs the Nim toolchain installs libpcre":
    ## Nim's `re` binds the system PCRE 1 library at run time. A workflow that
    ## installs the pinned Nim packages without installing the library dies with
    ## "could not load: libpcre.so" on the pinned runner image.
    let workflows = repoDir / ".github" / "workflows"
    var checked = 0
    for kind, path in walkDir(workflows):
      if kind != pcFile or not path.endsWith(".yml"):
        continue
      let text = readFile(path)
      if "./task deps-install" notin text:
        continue
      inc checked
      let installed = text.contains("apt-get install -y libpcre3")
      check installed
      if not installed:
        checkpoint(path.extractFilename & " runs Nim without libpcre3")
    check checked >= 4
