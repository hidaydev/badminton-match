## TL-11: `./task release` reads git and writes only with `--apply`.
##
## Every case that needs git builds its own repository under the temporary
## directory, so the working tree is never touched. `main*` is the single export
## this item added to production code (D-5): the CLI cases re-execute this binary
## with the probe variable set, so `main()` sees the argument list under test,
## the same way `tools/fixtures/tests/fixtures_test.nim` drives `parseArgs`.
##
## `repo.nim` is included rather than imported because `parseRecord` is private
## and D-5 allows one export per item, already spent on `main`. The include
## compiles the same source the shipped binary uses, and its line info still
## points at `repo.nim`, so the case covers the real parser.
import std/[os, osproc, strtabs, strutils, unittest]

include ../repo
import ../main
import ../versioning

const cliProbe = "RELEASE_TEST_CLI"

proc probeEnv(): StringTableRef =
  result = newStringTable(modeCaseSensitive)
  for (key, item) in envPairs():
    result[key] = item
  result[cliProbe] = "release"

proc selfRun(args: seq[string]): tuple[output: string, exitCode: int] =
  ## Runs the real `main()` in a child process that is this same binary.
  var binary = getAppFilename()
  if not binary.isAbsolute:
    binary = getCurrentDir() / binary
  var command = quoteShell(binary)
  for argument in args:
    command.add " " & quoteShell(argument)
  execCmdEx(command, env = probeEnv())

when isMainModule:
  # The probe branch runs before any suite is registered, so a probe run never
  # executes the rest of this file.
  if getEnv(cliProbe) == "release":
    main()
    quit(0)

var repoCounter = 0

proc newRepo(label: string): string =
  ## A fresh repository with a local identity: the operator's global git config
  ## is never consulted, so a machine without one still runs the suite.
  inc repoCounter
  result = getTempDir() / ("majadu-release-" & $getCurrentProcessId() & "-" &
    label & "-" & $repoCounter)
  removeDir(result)
  createDir(result)
  discard git(result, @["init", "-q"])
  discard git(result, @["config", "user.name", "Release Test"])
  discard git(result, @["config", "user.email", "release-test@example.invalid"])
  discard git(result, @["config", "commit.gpgsign", "false"])
  discard git(result, @["config", "tag.gpgSign", "false"])

proc currentBranch(repo: string): string =
  git(repo, @["symbolic-ref", "--short", "HEAD"]).strip()

proc commitFiles(repo, subject, body: string,
                 files: openArray[(string, string)]): string =
  for (path, content) in files:
    let full = repo / path
    createDir(parentDir(full))
    writeFile(full, content)
  discard git(repo, @["add", "-A"])
  var args = @["commit", "-q", "-m", subject]
  if body.len > 0:
    args.add "-m"
    args.add body
  discard git(repo, args)
  git(repo, @["rev-parse", "HEAD"]).strip()

proc emptyCommit(repo, subject: string): string =
  discard git(repo, @["commit", "-q", "--allow-empty", "-m", subject])
  git(repo, @["rev-parse", "HEAD"]).strip()

proc taggedRepo(label, version: string): string =
  ## One commit that carries VERSION, tagged `v<version>`.
  result = newRepo(label)
  discard commitFiles(result, "feat: initial import", "",
    [("VERSION", version & "\n")])
  discard git(result, @["tag", "v" & version])

proc echoedSection(output: string): seq[string] =
  ## The lines `report` echoes under `section:`, with its two space indent
  ## removed. The list ends at the blank line that precedes `next steps`;
  ## `preview` ends its text with a newline, so the echoed copy carries one
  ## trailing empty line that is dropped here.
  var collecting = false
  for line in output.splitLines():
    if collecting:
      if line.len == 0:
        break
      result.add(if line.len < 2: "" else: line[2 .. ^1])
    elif line == "section:":
      collecting = true
  while result.len > 0 and result[^1].len == 0:
    result.setLen(result.len - 1)

suite "release git helpers":
  test "logCommits returns each commit since a tag with subject, body and paths":
    let repo = newRepo("log")
    discard commitFiles(repo, "feat: first", "first body",
      [("a.txt", "a\n")])
    discard commitFiles(repo, "fix: second", "",
      [("b.txt", "b\n"), ("c.txt", "c\n")])
    discard git(repo, @["tag", "v1.0.0"])
    let head = commitFiles(repo, "feat: third", "third body",
      [("d.txt", "d\n")])

    let sinceTag = logCommits(repo, "v1.0.0")
    check sinceTag.len == 1
    check sinceTag[0].hash == head
    check sinceTag[0].subject == "feat: third"
    check sinceTag[0].body.strip() == "third body"
    check sinceTag[0].paths == @["d.txt"]
    check sinceTag[0].conventional
    check sinceTag[0].ctype == "feat"
    # An empty baseline walks every commit, which is the `--baseline` path.
    check logCommits(repo, "").len == 3

  test "logCommits leaves out merge commits":
    let repo = newRepo("merge")
    discard commitFiles(repo, "feat: base", "", [("base.txt", "base\n")])
    let mainline = currentBranch(repo)
    discard git(repo, @["branch", "side"])
    discard commitFiles(repo, "fix: mainline", "", [("main.txt", "m\n")])
    discard git(repo, @["checkout", "-q", "side"])
    discard commitFiles(repo, "feat: sideline", "", [("side.txt", "s\n")])
    discard git(repo, @["checkout", "-q", mainline])
    discard git(repo, @["merge", "-q", "--no-ff", "-m", "Merge branch 'side'",
      "side"])

    let commits = logCommits(repo, "")
    # base, mainline and sideline survive; the merge that joins them does not.
    check commits.len == 3
    var subjects: seq[string]
    for item in commits:
      check not item.subject.startsWith("Merge branch")
      subjects.add item.subject
    check subjects.contains("feat: sideline")

  test "parseRecord ignores a record without the record separator":
    check parseRecord("").hash == ""
    check parseRecord("deadbeef\x1ffeat: subject\x1fbody").hash == ""

  test "parseRecord ignores a record with fewer than three fields":
    check parseRecord("deadbeef\x1ffeat: subject\x1d\nfile.txt").hash == ""
    # Three fields with an empty hash is the same refusal.
    check parseRecord("\x1ffeat: subject\x1fbody\x1d\nfile.txt").hash == ""

  test "parseRecord keeps the hash, the header, the body and the paths":
    let record = "0123456789abcdef0123456789abcdef01234567" &
      "\x1ffeat(api): add board\x1fwhy it changed\x1d\n\n" &
      "apps/api/src/app.nim\nREADME.md\n\n"
    let parsed = parseRecord(record)
    check parsed.hash == "0123456789abcdef0123456789abcdef01234567"
    check parsed.subject == "feat(api): add board"
    check parsed.body.strip() == "why it changed"
    check parsed.paths == @["apps/api/src/app.nim", "README.md"]
    check parsed.conventional
    check parsed.ctype == "feat"
    check parsed.scope == "api"

  test "lastTag is empty without a tag and the tag name with one":
    let repo = newRepo("tag")
    discard commitFiles(repo, "feat: base", "", [("a.txt", "a\n")])
    check lastTag(repo) == ""
    discard git(repo, @["tag", "v0.2.0"])
    check lastTag(repo) == "v0.2.0"

  test "isDirty follows the working tree from edit to commit":
    let repo = newRepo("dirty")
    discard commitFiles(repo, "feat: base", "", [("a.txt", "one\n")])
    check not isDirty(repo)
    writeFile(repo / "a.txt", "two\n")
    check isDirty(repo)
    discard git(repo, @["add", "-A"])
    # A staged change is still an uncommitted change.
    check isDirty(repo)
    discard git(repo, @["commit", "-q", "-m", "fix: second"])
    check not isDirty(repo)

suite "release command line":
  test "a feat commit prints the next minor version and writes nothing":
    let repo = taggedRepo("dry", "1.4.2")
    discard commitFiles(repo, "feat: add the board", "a body",
      [("board.txt", "b\n")])

    let run = selfRun(@["--repo", repo, "--date", "2026-11-08"])
    check run.exitCode == 0
    check run.output.contains("release: dry run (no files written)")
    check run.output.contains("current:   1.4.2")
    check run.output.contains("baseline:  since v1.4.2")
    check run.output.contains("commits:   1 (0 breaking, 1 feat, 0 fix/perf, 0 other)")
    check run.output.contains("bump:      minor")
    check run.output.contains("next:      1.5.0 (tag v1.5.0)")
    check run.output.contains("## [1.5.0] - 2026-11-08")
    # Nothing is written without `--apply`, so the repository stays as it was.
    check readFile(repo / "VERSION") == "1.4.2\n"
    check not fileExists(repo / "CHANGELOG.md")
    check not dirExists(repo / ".cache")
    check not isDirty(repo)

  test "--apply writes VERSION, CHANGELOG.md, the tag notes and prints the commands":
    let repo = taggedRepo("apply", "1.4.2")
    discard commitFiles(repo, "feat: add the board", "",
      [("board.txt", "b\n")])

    let run = selfRun(@["--repo", repo, "--date", "2026-11-08", "--apply"])
    check run.exitCode == 0
    check run.output.contains("release: apply")
    check run.output.contains("release: wrote VERSION, CHANGELOG.md and .cache/release/v1.5.0.md")
    check run.output.contains("  git add VERSION CHANGELOG.md")
    check run.output.contains("  git tag -s -F .cache/release/v1.5.0.md v1.5.0")
    check run.output.contains("  git push origin main")
    check run.output.contains("  git push origin refs/tags/v1.5.0")
    check run.output.contains(
      "  gh release create v1.5.0 --notes-file .cache/release/v1.5.0.md --verify-tag")

    check readFile(repo / "VERSION") == "1.5.0\n"
    let changelog = readFile(repo / "CHANGELOG.md")
    check changelog.startsWith("# Changelog\n")
    check changelog.contains("## [1.5.0] - 2026-11-08")
    check changelog.contains("### Added")
    check changelog.contains("- feat: add the board")
    let notes = repo / ".cache/release/v1.5.0.md"
    check fileExists(notes)
    check readFile(notes).startsWith("## [1.5.0] - 2026-11-08\n")
    check readFile(notes).contains("### Added")
    # The tool never commits or tags on its own.
    check git(repo, @["tag"]).strip() == "v1.4.2"

  test "a dirty working tree is refused before anything is written":
    let repo = taggedRepo("dirty-refusal", "1.4.2")
    discard commitFiles(repo, "feat: add the board", "", [("board.txt", "b\n")])
    writeFile(repo / "uncommitted.txt", "x\n")

    let run = selfRun(@["--repo", repo, "--date", "2026-11-08", "--apply"])
    check run.exitCode == 1
    check run.output.contains("working tree is dirty")
    check readFile(repo / "VERSION") == "1.4.2\n"
    check not fileExists(repo / "CHANGELOG.md")
    check not dirExists(repo / ".cache")

  test "a last tag that does not match VERSION is refused":
    let repo = taggedRepo("mismatch", "2.0.0")
    discard git(repo, @["tag", "-d", "v2.0.0"])
    discard git(repo, @["tag", "v1.9.0"])

    let run = selfRun(@["--repo", repo, "--date", "2026-11-08", "--apply"])
    check run.exitCode == 1
    check run.output.contains("last tag v1.9.0 does not match VERSION 2.0.0")
    check readFile(repo / "VERSION") == "2.0.0\n"
    check not fileExists(repo / "CHANGELOG.md")

  test "a repository without a tag needs --baseline":
    let repo = newRepo("no-tag")
    discard commitFiles(repo, "feat: initial import", "",
      [("VERSION", "0.1.0\n")])

    let refused = selfRun(@["--repo", repo, "--date", "2026-11-08", "--apply"])
    check refused.exitCode == 1
    check refused.output.contains("no baseline tag: create v0.1.0 first")
    check not fileExists(repo / "CHANGELOG.md")

    let accepted = selfRun(@["--repo", repo, "--date", "2026-11-08",
      "--baseline"])
    check accepted.exitCode == 0
    check accepted.output.contains("baseline:  no tag yet: every commit")
    check accepted.output.contains("bump:      none")
    check accepted.output.contains("commits:   0 (0 breaking, 0 feat, 0 fix/perf, 0 other)")
    check accepted.output.contains("next:      0.1.0 (tag v0.1.0)")
    check readFile(repo / "VERSION") == "0.1.0\n"
    check not fileExists(repo / "CHANGELOG.md")

  test "a section longer than 40 lines is previewed with the remainder counted":
    let repo = taggedRepo("preview", "1.0.0")
    for index in 1 .. 45:
      discard emptyCommit(repo, "fix: item " & align($index, 2, '0'))

    let run = selfRun(@["--repo", repo, "--date", "2026-11-08"])
    check run.exitCode == 0
    # The section is 49 lines once `renderSection`'s trailing newline is
    # counted; `preview` keeps the first 40 and names the remaining 9.
    let printed = echoedSection(run.output)
    check printed.len == 41
    check printed[0] == "## [1.0.1] - 2026-11-08"
    check printed[^1].strip() ==
      "... (9 more lines; --apply writes all of them)"
    check not run.output.contains("... (0 more lines")