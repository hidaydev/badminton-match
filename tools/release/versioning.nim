## Conventional Commits parsing and SemVer 2.0 bump rules for `./task release`.
##
## The rules stay deliberately small: a breaking marker wins, `feat` is a minor
## bump, `fix`/`perf` are a patch bump, and every other type changes nothing.
## Prerelease publishing is not part of this tool; a bump always increments the
## numeric core of VERSION and drops any `-prerelease`/`+build` suffix.
import std/[strutils]

type
  Bump* = enum
    bNone = "none"
    bPatch = "patch"
    bMinor = "minor"
    bMajor = "major"

  Version* = object
    major*: int
    minor*: int
    patch*: int
    prerelease*: string
    build*: string

  ChangeGroup* = enum
    cgBreaking = "Breaking"
    cgAdded = "Added"
    cgChanged = "Changed"
    cgFixed = "Fixed"

  Commit* = object
    hash*: string
    subject*: string
    body*: string
    ctype*: string
    scope*: string
    conventional*: bool
    breaking*: bool
    paths*: seq[string]

  ChangeCounts* = object
    breaking*: int
    added*: int
    fixed*: int
    other*: int

proc parseVersion*(raw: string): Version =
  ## Parses `MAJOR.MINOR.PATCH[-prerelease][+build]`. Raises ValueError on
  ## anything else, including the leading zeros SemVer forbids.
  let text = raw.strip()
  if text.len == 0:
    raise newException(ValueError, "version is empty")
  var core = text
  let buildAt = core.find('+')
  if buildAt >= 0:
    result.build = core[buildAt + 1 .. ^1]
    core = core[0 ..< buildAt]
  let preAt = core.find('-')
  if preAt >= 0:
    result.prerelease = core[preAt + 1 .. ^1]
    core = core[0 ..< preAt]
  let parts = core.split('.')
  if parts.len != 3:
    raise newException(ValueError, "expected MAJOR.MINOR.PATCH, got " & text)
  var numbers: array[3, int]
  for index, part in parts:
    if part.len == 0 or not part.allCharsInSet({'0' .. '9'}):
      raise newException(ValueError, "not a number: " & part)
    if part.len > 1 and part[0] == '0':
      raise newException(ValueError, "leading zero in " & part)
    numbers[index] = parseInt(part)
  result.major = numbers[0]
  result.minor = numbers[1]
  result.patch = numbers[2]

proc `$`*(version: Version): string =
  result = $version.major & "." & $version.minor & "." & $version.patch
  if version.prerelease.len > 0:
    result.add "-" & version.prerelease
  if version.build.len > 0:
    result.add "+" & version.build

proc bumped*(current: Version, bump: Bump): Version =
  case bump
  of bNone:
    current
  of bPatch:
    Version(major: current.major, minor: current.minor, patch: current.patch + 1)
  of bMinor:
    Version(major: current.major, minor: current.minor + 1)
  of bMajor:
    Version(major: current.major + 1)

proc parseHeader*(subject: string): tuple[ctype, scope: string, bang, ok: bool] =
  ## Splits a Conventional Commit header. A type is a lowercase ASCII word, so
  ## free-form subjects such as "Fix/remove logo" stay unconventional.
  result = ("", "", false, false)
  let colon = subject.find(": ")
  if colon <= 0:
    return
  var head = subject[0 ..< colon]
  if head.len > 1 and head[^1] == '!':
    result.bang = true
    head.setLen(head.len - 1)
  let paren = head.find('(')
  if paren > 0:
    if head[^1] != ')':
      return
    result.scope = head[paren + 1 ..< head.len - 1]
    head = head[0 ..< paren]
  if head.len == 0:
    return
  for letter in head:
    if letter notin {'a' .. 'z'}:
      return
  if subject[colon + 2 .. ^1].strip().len == 0:
    return
  result.ctype = head
  result.ok = true

proc hasBreakingFooter*(body: string): bool =
  for line in body.splitLines():
    let trimmed = line.strip()
    if trimmed.startsWith("BREAKING CHANGE:") or
       trimmed.startsWith("BREAKING-CHANGE:"):
      return true

proc parseCommit*(hash, subject, body: string, paths: seq[string]): Commit =
  result = Commit(hash: hash, subject: subject, body: body, paths: paths)
  let header = parseHeader(subject)
  if header.ok:
    result.conventional = true
    result.ctype = header.ctype
    result.scope = header.scope
  result.breaking = (header.ok and header.bang) or hasBreakingFooter(body)

proc decideBump*(commits: seq[Commit]): Bump =
  result = bNone
  for commit in commits:
    if commit.breaking:
      return bMajor
    if not commit.conventional:
      continue
    if commit.ctype == "feat":
      result = bMinor
    elif commit.ctype in ["fix", "perf"] and result < bPatch:
      result = bPatch

proc groupOf*(commit: Commit): ChangeGroup =
  if commit.breaking:
    cgBreaking
  elif commit.ctype == "feat":
    cgAdded
  elif commit.ctype in ["fix", "perf"]:
    cgFixed
  else:
    cgChanged

proc summarize*(commits: seq[Commit]): ChangeCounts =
  for commit in commits:
    case groupOf(commit)
    of cgBreaking:
      result.breaking.inc
    of cgAdded:
      result.added.inc
    of cgFixed:
      result.fixed.inc
    of cgChanged:
      result.other.inc
