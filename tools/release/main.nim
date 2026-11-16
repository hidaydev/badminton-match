## `./task release` backend: computes the next SemVer 2.0 version from
## Conventional Commits, renders the CHANGELOG.md section and, with `--apply`,
## writes VERSION and prepends the section. It never creates tags, commits or
## pushes; it prints those commands for the operator.
import std/[os, strutils, times]
import sha256
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

# The v2 parity corpus pins the `/version` body, and the API builds that body
# from VERSION. A bump that moves one and not the other fails the release gate at
# `Parity: v2 verify`, so the pin is rewritten here instead of being left for the
# operator to remember.
const parityVersionPin = "testdata/parity/v2/version.json"

# `parity v2 lint` hashes every corpus file against this manifest before it
# replays anything, so a rewritten pin that keeps the old digest fails the
# release commit on the contract job.
const parityManifest = "testdata/parity/v2/MANIFEST.sha256"
const parityPinEntry = "./version.json"

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

proc refreshParityDigest(repo, content: string) =
  ## Replace the `./version.json` line of the corpus manifest with the digest of
  ## the rewritten file, leaving every other line byte for byte.
  let manifestPath = repo / parityManifest
  if not fileExists(manifestPath):
    return
  let digest = sha256Hex(content)
  # Split on `\n` instead of `splitLines`: the latter drops nothing and appends
  # nothing, so joining reproduces the file byte for byte, trailing newline
  # included.
  var lines = readFile(manifestPath).split('\n')
  for i in 0 ..< lines.len:
    let cols = lines[i].splitWhitespace()
    if cols.len == 2 and cols[1] == parityPinEntry:
      lines[i] = digest & "  " & parityPinEntry
  writeAtomic(manifestPath, lines.join("\n"))

proc repinParityVersion(repo: string, current, next: Version): bool =
  ## Rewrite the pinned `/version` body in the v2 parity corpus. Returns false
  ## when the corpus or the pin is absent, which is not an error: the file only
  ## exists in the v2 tree.
  let path = repo / parityVersionPin
  if not fileExists(path):
    return false
  let body = readFile(path)
  let pinned = "\"version\": \"" & $current & "\""
  if not body.contains(pinned):
    return false
  let rewritten = body.replace(pinned, "\"version\": \"" & $next & "\"")
  writeAtomic(path, rewritten)
  refreshParityDigest(repo, rewritten)
  true

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
  if fileExists(options.repo / parityVersionPin):
    echo "  " & parityVersionPin & "  pin " & $current & " -> " & $next
  if fileExists(options.repo / parityManifest):
    echo "  " & parityManifest & "  digest of " & parityPinEntry
  echo "  " & notesPath & " annotated tag notes"
  echo ""
  echo "section:"
  for line in preview(section).splitLines():
    echo "  " & line
  echo ""
  echo "next steps (run by hand from the repository root; nothing is tagged or pushed here):"
  echo "  git add VERSION CHANGELOG.md" &
    (if fileExists(options.repo / parityVersionPin): " " & parityVersionPin else: "") &
    (if fileExists(options.repo / parityManifest): " " & parityManifest else: "")
  echo "  git commit -m \"chore(release): v" & $next & "\""
  # QA-15: `Release: verify tag` wants a completed, successful Coverage run for
  # the exact tagged commit, and Coverage only runs on main, release/** and pull
  # requests. Tagging a commit that was never pushed therefore waits five minutes
  # and fails, so the commit goes to a release branch first and the tag follows a
  # green run.
  echo "  git push origin HEAD:refs/heads/release/v" & $next &
    "   # CI + Coverage for this commit; wait for both to go green"
  # SEC-03: release.yml verifies the tag with `git verify-tag` against
  # `.github/allowed_signers` under `gpg.format=ssh`. A bare `git tag -s` follows
  # the committer's default, which is OpenPGP here, and the gate rejects that
  # signature, so the format is stated on the command line instead of assumed
  # from configuration the operator cannot see from this output.
  echo "  git -c gpg.format=ssh -c user.signingkey=~/.ssh/id_ed25519.pub \\"
  echo "    tag -s -F " & notesPath & " v" & $next
  echo "  git -c gpg.format=ssh -c gpg.ssh.allowedSignersFile=.github/allowed_signers \\"
  echo "    verify-tag v" & $next & "   # the gate's own check, run it before pushing"
  # The tag must be pushed before main: the deploy webhook on main reads the
  # release that the tag run publishes, and the reverse order makes the deploy
  # fail at resolve-digest.
  echo "  git push origin refs/tags/v" & $next
  echo "  git push origin HEAD:main"
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
      " first (an SSH-signed `git tag -s`, see docs/ops/release.md), or pass " &
      "--baseline to cut " & $current & " as the first release")
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
  if repinParityVersion(options.repo, current, next):
    echo "release: rewrote the " & parityVersionPin & " pin to " & $next
  echo ""
  echo "release: wrote VERSION, CHANGELOG.md and " & notesPath

when isMainModule:
  main()
