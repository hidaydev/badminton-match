## `./task release` backend: computes the next SemVer 2.0 version from
## Conventional Commits, renders the CHANGELOG.md section and, with `--apply`,
## writes VERSION and prepends the section. It never creates tags, commits or
## pushes; it prints those commands for the operator.
import std/[os, strutils, times]
import cli
import clock
import versioning, changelog, repo

const
  program = "release"
  usage = """Usage: majadu-release [--repo DIR] [--dry-run|--apply] [--date YYYY-MM-DD]

  --dry-run   compute and print only (default)
  --apply     write VERSION, prepend CHANGELOG.md and write the tag notes
  --date      release date for the section heading (default: today, UTC)
  --baseline  cut the current VERSION as the first release when no tag exists

The bump follows Conventional Commits since the last tag: a `!` marker or a
`BREAKING CHANGE:` footer is major, `feat` is minor, `fix`/`perf` are patch, and
anything else is not a release on its own. VERSION must match the last tag."""

const previewLimit = 40

type Options = object
  repo: string
  apply: bool
  date: string
  baseline: bool

proc parseArgs(): Options =
  result = Options(repo: getCurrentDir(), apply: false)
  for (flag, value) in flags(program, 1, ["--repo", "--date"]):
    case flag
    of "--repo":
      result.repo = value
    of "--apply":
      result.apply = true
    of "--dry-run":
      result.apply = false
    of "--baseline":
      result.baseline = true
    of "--date":
      result.date = value
    of "-h", "--help":
      echo usage
      quit(0)
    else:
      usageFail(program, "unknown argument: " & flag)
  if result.date.len == 0:
    result.date = utcNow().format("yyyy-MM-dd")

proc readVersion(path: string): Version =
  if not fileExists(path):
    fail(program, "missing " & path)
  try:
    parseVersion(readFile(path))
  except ValueError as error:
    fail(program, path & ": " & error.msg)

proc baselineLabel(tag: string): string =
  if tag.len == 0:
    "no tag yet: every commit"
  else:
    "since " & tag

proc countLine(commits: seq[Commit]): string =
  let counts = summarize(commits)
  $commits.len & " (" & $counts.breaking & " breaking, " & $counts.added &
    " feat, " & $counts.fixed & " fix/perf, " & $counts.other & " other)"

proc preview(section: string): string =
  let lines = section.splitLines()
  if lines.len <= previewLimit:
    return section
  lines[0 ..< previewLimit].join("\n") & "\n  ... (" &
    $(lines.len - previewLimit) & " more lines; --apply writes all of them)\n"

proc writeAtomic(path, content: string) =
  let parent = parentDir(path)
  if parent.len > 0:
    createDir(parent)
  let staging = path & ".release-tmp"
  writeFile(staging, content)
  moveFile(staging, path)

proc report(options: Options, current, next: Version, tag: string,
            bump: Bump, commits: seq[Commit], section, notesPath: string) =
  let verb = if options.apply: "apply" else: "dry run (no files written)"
  echo "release: " & verb
  echo "repo:      " & options.repo
  echo "current:   " & $current
  echo "baseline:  " & baselineLabel(tag)
  echo "commits:   " & countLine(commits)
  echo "bump:      " & $bump
  echo "next:      " & $next & " (tag v" & $next & ")"
  echo ""
  echo "files:"
  echo "  VERSION                  " & $current & " -> " & $next
  echo "  CHANGELOG.md             prepend section for " & $next
  echo "  " & notesPath & " annotated tag notes"
  echo ""
  echo "section:"
  for line in preview(section).splitLines():
    echo "  " & line
  echo ""
  echo "next steps (run by hand from the repository root; nothing is tagged or pushed here):"
  echo "  git add VERSION CHANGELOG.md"
  echo "  git commit -m \"chore(release): v" & $next & "\""
  echo "  git tag -s -F " & notesPath & " v" & $next
  # The tag must be pushed before main: the deploy webhook on main reads the
  # release that the tag run publishes, and the reverse order makes the deploy
  # fail at resolve-digest.
  echo "  git push origin refs/tags/v" & $next
  echo "  git push origin main"
  echo "  gh release view v" & $next &
    "   # release.yml creates it and records the image digest"
  echo "  # only if the workflow is unavailable:"
  echo "  gh release create v" & $next & " --notes-file " & notesPath &
    " --verify-tag"

proc main*() =
  ## Exported for `tests/repo_test.nim` only (D-5): `main` reads the process
  ## command line, so the CLI cases re-execute the test binary through an
  ## environment probe and call this entry point with the probe's arguments.
  ## Shipped behaviour is unchanged; `when isMainModule` still gates the tool.
  let options = parseArgs()
  let current = readVersion(options.repo / "VERSION")
  let tag = lastTag(options.repo)
  if tag.len > 0 and tag != "v" & $current:
    fail(program, "last tag " & tag & " does not match VERSION " & $current &
      "; bump VERSION with the release that created the tag")
  if tag.len == 0 and not options.baseline:
    fail(program, "no baseline tag: create v" & $current &
      " first (git tag -s v" & $current & "), or pass --baseline to cut " &
      $current & " as the first release")
  if isDirty(options.repo):
    fail(program, "working tree is dirty; commit or stash before preparing a release")
  var commits: seq[Commit] = @[]
  var bump = bNone
  if not (tag.len == 0 and options.baseline):
    commits = logCommits(options.repo, tag)
    bump = decideBump(commits)
    if bump == bNone:
      fail(program, "no commit since " & tag & " is feat, fix, perf or breaking")
  let next = if bump == bNone: current else: bumped(current, bump)
  let section = renderSection($next, options.date, commits)
  let notesPath = ".cache/release/v" & $next & ".md"
  report(options, current, next, tag, bump, commits, section, notesPath)
  if not options.apply:
    return
  let changelogPath = options.repo / "CHANGELOG.md"
  let existing = if fileExists(changelogPath): readFile(changelogPath) else: ""
  writeAtomic(changelogPath, insertSection(existing, section))
  writeAtomic(options.repo / notesPath, section)
  writeAtomic(options.repo / "VERSION", $next & "\n")
  echo ""
  echo "release: wrote VERSION, CHANGELOG.md and " & notesPath

when isMainModule:
  main()
