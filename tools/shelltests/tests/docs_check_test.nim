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
  touch(fixture.root / "apps" / "api" / "src" / "app.nim", "# app\n")
  touch(fixture.root / "package.json",
    "{\n  \"packageManager\": \"pnpm@12.17.0\"\n}\n")
  touch(fixture.root / ".github" / "workflows" / "ci.yml",
    "jobs:\n  web:\n    steps:\n      - uses: actions/setup-node@x\n" &
    "        with:\n          node-version: 26\n")
  touch(fixture.root / "CONTRIBUTING.md",
    "| Node.js | 26 | `.github/workflows/ci.yml` |\n" &
    "| pnpm | 12.17.0 | `packageManager` in `package.json` |\n")
  touch(fixture.root / "docs" / "handbook" / "requirements.md",
    "| REQ-001 | a requirement | `apps/api/src/app.nim` | met |\n")

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

suite "supplier register":
  # ISO-17: every service the product depends on is named once, and the second
  # origin for the SPA is in the repository instead of in an incident note.
  test "suppliers.md lists every external service":
    let text = readFile(repoDir / "docs" / "ops" / "suppliers.md")
    for service in ["Vercel", "GitHub", "GHCR", "Google", "VPS provider",
                    "Alert webhook"]:
      check text.contains(service)
    for column in ["Exit path", "Data it receives", "Owner"]:
      check text.contains(column)

  test "the static fallback origin proxies /api and serves the built shell":
    let caddy = readFile(repoDir / "ops" / "caddy" / "site-web-fallback.caddy")
    check caddy.contains("handle /api/*")
    check caddy.contains("rewrite * /majadu{uri}")
    check caddy.contains("try_files {path} /index.html")
    check caddy.contains("file_server")
    check caddy.contains("Content-Security-Policy")

suite "incident policy":
  # ISO-18: the incident note is a form; the policy is what decides who is
  # woken and who is told.
  test "operations.md carries a severity model and a user-notice rule":
    let text = readFile(repoDir / "docs" / "ops" / "operations.md")
    for level in ["SEV-1", "SEV-2", "SEV-3", "SEV-4"]:
      check text.contains(level)
    check text.contains("Containment target")
    check text.contains("within 72 hours")
    check text.contains("tabletop exercise")
    check text.contains("MAJADU_BACKUP_DIR/incidents/")

  test "a requirement whose evidence file is gone fails the gate":
    let fixture = newFixture("docs-requirement-missing")
    defer: removeDir(fixture.root)
    seed(fixture)
    let register = fixture.root / "docs" / "handbook" / "requirements.md"
    writeFile(register, readFile(register) &
      "| REQ-999 | a requirement with no test | `modules/gone/gone_test.nim` | met |\n")
    let result = fixture.runTask(@["docs-check"])
    check result.exitCode == 1
    check result.stderr.contains("references modules/gone/gone_test.nim")

  test "a CONTRIBUTING version that drifts from its source fails":
    let fixture = newFixture("docs-tool-version")
    defer: removeDir(fixture.root)
    seed(fixture)
    let contributing = fixture.root / "CONTRIBUTING.md"
    writeFile(contributing,
      readFile(contributing).replace("| Node.js | 26 |", "| Node.js | 22 |"))
    let result = fixture.runTask(@["docs-check"])
    check result.exitCode == 1
    check result.stderr.contains("does not state Node.js 26")

suite "locale statement":
  # ISO-23: a single-locale product is a decision; the user-facing document has
  # to say so instead of leaving it to the reader.
  test "product-overview names the supported locale and the legacy limit":
    let text = readFile(repoDir / "docs" / "handbook" / "product-overview.md")
    check text.contains("## Language and locale")
    check text.contains("English (`en`)")
    check text.contains("RSK-005")
    let register = readFile(repoDir / "docs" / "handbook" / "requirements.md")
    check register.contains("| RSK-005 |")
