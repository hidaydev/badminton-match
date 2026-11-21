import std/[os, strutils, unittest]
import ../harness

# QA-13: a lower-coverage file needs a dated exception, but the manifest must
# not become a list of lies. This suite drives the guard in both directions.

proc writeBaseline(fixture: Fixture, path, lines, covered: string) =
  createDir(fixture.root / "docs" / "handbook")
  writeFile(fixture.root / "coverage-baseline-linux.json",
    "{\n" &
    "  \"floor\": 10.0,\n" &
    "  \"total\": {\"lines\": " & lines & ", \"covered\": " & covered & "},\n" &
    "  \"domains\": {\n" &
    "  },\n" &
    "  \"files\": {\n" &
    "    \"" & path & "\": {\"lines\": " & lines & ", \"covered\": " & covered & "}\n" &
    "  }\n" &
    "}\n")

proc writeManifest(fixture: Fixture, body: string) =
  writeFile(fixture.root / "docs" / "handbook" / "coverage-debt.json",
    "{\n  \"entries\": [\n" & body & "\n  ]\n}\n")

suite "coverage debt manifest":
  test "a low file with a dated exception passes":
    let fixture = newFixture("debt-ok")
    defer: removeDir(fixture.root)
    fixture.writeBaseline("tools/low/main.nim", "10", "0")
    fixture.writeManifest(
      """    {"path": "tools/low/main.nim", "owner": "qa", "expires": "2099-01-01"}""")
    let result = fixture.runTask(@["coverage-debt"])
    check result.exitCode == 0
    check result.stdout.contains("coverage-debt: ok")

  test "a low file with no exception fails":
    let fixture = newFixture("debt-missing")
    defer: removeDir(fixture.root)
    fixture.writeBaseline("tools/low/main.nim", "10", "0")
    fixture.writeManifest("")
    let result = fixture.runTask(@["coverage-debt"])
    check result.exitCode == 1
    check result.stderr.contains("tools/low/main.nim is below 80%")

  test "an expired exception fails":
    let fixture = newFixture("debt-expired")
    defer: removeDir(fixture.root)
    fixture.writeBaseline("tools/low/main.nim", "10", "0")
    fixture.writeManifest(
      """    {"path": "tools/low/main.nim", "owner": "qa", "expires": "2000-01-01"}""")
    let result = fixture.runTask(@["coverage-debt"])
    check result.exitCode == 1
    check result.stderr.contains("expired on 2000-01-01")

  test "an exception for a file that is no longer low fails":
    let fixture = newFixture("debt-stale")
    defer: removeDir(fixture.root)
    fixture.writeBaseline("tools/fine/main.nim", "10", "10")
    fixture.writeManifest(
      """    {"path": "tools/fine/main.nim", "owner": "qa", "expires": "2099-01-01"}""")
    let result = fixture.runTask(@["coverage-debt"])
    check result.exitCode == 1
    check result.stderr.contains("is stale")

  test "an entry without an owner fails":
    let fixture = newFixture("debt-malformed")
    defer: removeDir(fixture.root)
    fixture.writeBaseline("tools/low/main.nim", "10", "0")
    fixture.writeManifest("""    {"path": "tools/low/main.nim", "expires": "2099-01-01"}""")
    let result = fixture.runTask(@["coverage-debt"])
    check result.exitCode == 1
    check result.stderr.contains("malformed entry")

  # REL-QA-05: the guard read one line per entry, so an exception that wrapped
  # onto a second physical line vanished and its file was reported as having no
  # exception at all. The reader is structural now; the same JSON must behave the
  # same way however it is laid out.
  test "an exception wrapped over several lines still counts":
    let fixture = newFixture("debt-wrapped")
    defer: removeDir(fixture.root)
    fixture.writeBaseline("tools/low/main.nim", "10", "0")
    fixture.writeManifest(
      """    {
      "path": "tools/low/main.nim",
      "owner": "qa",
      "expires": "2099-01-01",
      "reason": "wrapped"
    }""")
    let result = fixture.runTask(@["coverage-debt"])
    check result.exitCode == 0
    check result.stdout.contains("coverage-debt: ok")

suite "quarantine register":
  # REL-QA-02: the per-line match skipped any entry that spanned more than one
  # physical line, so an expired quarantine passed by being reformatted. A
  # quarantined test that the gate cannot see is never fixed on time.
  test "an expired quarantine wrapped over several lines fails":
    let fixture = newFixture("flake-wrapped")
    defer: removeDir(fixture.root)
    writeFile(fixture.root / "docs" / "handbook" / "flaky-tests.json",
      "{\n  \"note\": \"fixture\",\n  \"entries\": [\n    {\n" &
      "      \"test\": \"e2e/visual.spec.ts\",\n" &
      "      \"owner\": \"qa\",\n" &
      "      \"firstSeen\": \"2026-01-01\",\n" &
      "      \"expires\": \"2026-02-01\",\n" &
      "      \"issue\": \"QA-999\"\n    }\n  ]\n}\n")
    let result = fixture.runTask(@["flakeregister"])
    check result.exitCode == 1
    check result.stderr.contains("e2e/visual.spec.ts: quarantine expired on 2026-02-01")

  test "a live quarantine wrapped over several lines passes and is counted":
    let fixture = newFixture("flake-wrapped-live")
    defer: removeDir(fixture.root)
    writeFile(fixture.root / "docs" / "handbook" / "flaky-tests.json",
      "{\n  \"note\": \"fixture\",\n  \"entries\": [\n    {\n" &
      "      \"test\": \"e2e/visual.spec.ts\",\n" &
      "      \"owner\": \"qa\",\n" &
      "      \"firstSeen\": \"2026-01-01\",\n" &
      "      \"expires\": \"2099-01-01\",\n" &
      "      \"issue\": \"QA-999\"\n    }\n  ]\n}\n")
    let result = fixture.runTask(@["flakeregister"])
    check result.exitCode == 0
    check result.stdout.contains("flakeregister: ok (1 quarantined)")

  test "a register without an entries array fails instead of reporting zero":
    let fixture = newFixture("flake-no-array")
    defer: removeDir(fixture.root)
    writeFile(fixture.root / "docs" / "handbook" / "flaky-tests.json",
      "\"test\": \"example\", \"owner\": \"qa\"\n")
    let result = fixture.runTask(@["flakeregister"])
    check result.exitCode == 1
    check result.stderr.contains("no \"entries\" array found")
