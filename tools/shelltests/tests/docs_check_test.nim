# OPS-25: the docs gate has to fail when a fixed contradiction comes back.
#
# The fixture is a minimal repository: the artefacts docs-check counts, the two
# documents it reads, and the task runner. No case reads the real README.

import std/[os, strutils, unittest]
import ../harness

proc touch(path: string, body = "") =
  createDir(path.parentDir)
  writeFile(path, body)

proc seed(fixture: Fixture) =
  touch(fixture.root / "db" / "migrations" / "0001_core.sql", "select 1;\n")
  touch(fixture.root / "packages" / "contracts" / "openapi" / "CONTRACT.sha256",
    "operations 75\n")
  touch(fixture.root / "README.md",
    "# Majadu\n\n1 migrations, 75 operations.\n")
  touch(fixture.root / "docs" / "handbook" / "current-status.md",
    "1 migrations, 75 operations.\n")
  touch(fixture.root / "docs" / "ops" / "operations.md",
    "The GHCR token is fine.\n\n| Every ten minutes | rotated |\n")
  touch(fixture.root / "docs" / "ops" / "release.md",
    "   git push origin refs/tags/v<version>\n   git push origin main\n")

suite "docs-check":
  test "a consistent tree passes":
    let fixture = newFixture("docs-ok")
    defer: removeDir(fixture.root)
    seed(fixture)
    let result = fixture.runTask(@["docs-check"])
    check result.exitCode == 0
    check result.stdout.contains("docs-check: ok")

  test "a reintroduced stale claim fails and names the file":
    let fixture = newFixture("docs-stale")
    defer: removeDir(fixture.root)
    seed(fixture)
    let ops = fixture.root / "docs" / "ops" / "operations.md"
    writeFile(ops, readFile(ops) & "\nThe GHCR token is stored in a CI secret.\n")
    let result = fixture.runTask(@["docs-check"])
    check result.exitCode == 1
    check result.stderr.contains("stored in a CI secret")

  test "a release page that pushes main first fails":
    let fixture = newFixture("docs-order")
    defer: removeDir(fixture.root)
    seed(fixture)
    writeFile(fixture.root / "docs" / "ops" / "release.md",
      "   git push origin main\n   git push origin refs/tags/v<version>\n")
    let result = fixture.runTask(@["docs-check"])
    check result.exitCode == 1
    check result.stderr.contains("pushes main before the tag")

  test "the committed ci target runs the docs gate":
    let fixture = newFixture("docs-ci-target")
    defer: removeDir(fixture.root)
    check readFile(fixture.root / "task.d" / "ci.sh")
      .contains("task.d/docs-check.sh")
