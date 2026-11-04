import std/[strutils, unittest]
import ../versioning
import ../changelog

proc commitOf(subject: string, body = "", paths: seq[string] = @[]): Commit =
  parseCommit("0123456789abcdef", subject, body, paths)

suite "versioning":
  test "semver round trip":
    check $parseVersion("2.0.0") == "2.0.0"
    check $parseVersion(" 2.10.3-rc.1+build.7\n") == "2.10.3-rc.1+build.7"

  test "semver rejects bad input":
    expect ValueError:
      discard parseVersion("2.0")
    expect ValueError:
      discard parseVersion("2.00.1")
    expect ValueError:
      discard parseVersion("v2.0.0")

  test "bump increments the right field and drops a prerelease":
    let base = parseVersion("2.3.4")
    check $bumped(base, bPatch) == "2.3.5"
    check $bumped(base, bMinor) == "2.4.0"
    check $bumped(base, bMajor) == "3.0.0"
    check $bumped(base, bNone) == "2.3.4"
    check $bumped(parseVersion("2.3.4-rc.2"), bMinor) == "2.4.0"

  test "conventional header":
    let header = parseHeader("feat(rating)!: add ticker")
    check header.ok
    check header.ctype == "feat"
    check header.scope == "rating"
    check header.bang

  test "non-conventional subjects stay unconventional":
    for subject in ["Fix/remove logo", "update instagram post (#34)",
                    "feat: ", "Feat: uppercase", "feat:x", "!: no type"]:
      check not parseHeader(subject).ok

  test "bump decision follows the commit types":
    check decideBump(@[commitOf("docs: spell")]) == bNone
    check decideBump(@[commitOf("chore: bump deps")]) == bNone
    check decideBump(@[commitOf("fix(api): crash")]) == bPatch
    check decideBump(@[commitOf("perf(rank): faster")]) == bPatch
    check decideBump(@[commitOf("feat(api): board")]) == bMinor
    check decideBump(@[commitOf("feat(api): board"), commitOf("fix: typo")]) == bMinor
    check decideBump(@[commitOf("fix: typo"), commitOf("feat(api)!: drop v1")]) == bMajor
    check decideBump(@[commitOf("feat: x", "BREAKING CHANGE: v1 is gone")]) == bMajor

  test "unconventional commits never change the version":
    check decideBump(@[commitOf("Fix/remove group score validation")]) == bNone

  test "groups":
    check groupOf(commitOf("feat(api)!: drop")) == cgBreaking
    check groupOf(commitOf("feat(api): add")) == cgAdded
    check groupOf(commitOf("fix: bug")) == cgFixed
    check groupOf(commitOf("docs: note")) == cgChanged
    check groupOf(commitOf("revert: feat(x)")) == cgChanged

  test "summary counts":
    let counts = summarize(@[commitOf("feat: a"), commitOf("fix: b"),
      commitOf("perf: c"), commitOf("docs: d"), commitOf("plain subject")])
    check counts.added == 1
    check counts.fixed == 2
    check counts.breaking == 0
    check counts.other == 2

suite "changelog":
  test "section keeps the group order and lists paths":
    let section = renderSection("2.1.0", "2026-11-04", @[
      commitOf("fix(api): crash", paths = @["apps/api/src/app.nim"]),
      commitOf("feat(rank): board", paths = @["a.nim", "b.nim", "c.nim", "d.nim"]),
      commitOf("feat(api)!: drop v1", paths = @["apps/api/src/main.nim"])])
    check section.startsWith("## [2.1.0] - 2026-11-04\n")
    check section.find("### Breaking") < section.find("### Added")
    check section.find("### Added") < section.find("### Fixed")
    check section.contains("- feat(rank): board (0123456; a.nim, b.nim, c.nim (+1 more))")
    check section.contains("- fix(api): crash (0123456; apps/api/src/app.nim)")

  test "empty section says so":
    check renderSection("2.0.1", "2026-11-04", @[]).contains("No commits")

  test "new file gets the preamble":
    let merged = insertSection("", "## [2.1.0] - 2026-11-04\n\n### Added\n- x\n")
    check merged.startsWith("# Changelog\n")
    check merged.contains("## [2.1.0] - 2026-11-04")

  test "existing history is preserved and stays below the new section":
    let existing = "# Changelog\n\nIntro.\n\n## [2.0.0] - 2026-10-01\n\n### Added\n- old\n"
    let merged = insertSection(existing, "## [2.1.0] - 2026-11-04\n\n### Fixed\n- new\n")
    check merged.contains("Intro.")
    check merged.contains("## [2.0.0] - 2026-10-01")
    check merged.contains("- old")
    check merged.find("## [2.1.0]") < merged.find("## [2.0.0]")
    check merged.endsWith("- old\n")

  test "a file without headings appends":
    let merged = insertSection("notes only\n", "## [2.1.0] - 2026-11-04\n")
    check merged.startsWith("notes only\n\n## [2.1.0]")
