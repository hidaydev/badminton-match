## Renders the CHANGELOG.md section for a release and merges it into an
## existing file without touching older entries.
import std/strutils
import versioning

const changelogPreamble* = """# Changelog

All notable changes to Majadu are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning 2.0](https://semver.org/spec/v2.0.0.html). Entries are
generated from Conventional Commits by `./task release`.

"""

const maxPaths* = 3

proc shortHash*(hash: string): string =
  hash[0 ..< min(7, hash.len)]

proc entryLine*(commit: Commit): string =
  ## One bullet: subject, abbreviated commit and up to `maxPaths` touched paths.
  var detail = shortHash(commit.hash)
  if commit.paths.len > 0:
    detail.add "; " & commit.paths[0 ..< min(maxPaths, commit.paths.len)].join(", ")
    if commit.paths.len > maxPaths:
      detail.add " (+" & $(commit.paths.len - maxPaths) & " more)"
  "- " & commit.subject & " (" & detail & ")"

proc renderSection*(version, date: string, commits: seq[Commit]): string =
  ## `Breaking`, `Added`, `Changed` and `Fixed` in that order; empty groups are
  ## omitted. The result ends with a single newline.
  var buckets: array[ChangeGroup, seq[Commit]]
  for commit in commits:
    buckets[groupOf(commit)].add(commit)
  result = "## [" & version & "] - " & date & "\n"
  if commits.len == 0:
    return result & "\n_No commits since the last release._\n"
  for group in [cgBreaking, cgAdded, cgChanged, cgFixed]:
    if buckets[group].len == 0:
      continue
    result.add "\n### " & $group & "\n"
    for commit in buckets[group]:
      result.add entryLine(commit) & "\n"

proc insertSection*(existing, section: string): string =
  ## Puts `section` above the newest existing `## ` heading, leaving the rest of
  ## the file byte for byte. An empty or missing file gets the preamble.
  if existing.strip().len == 0:
    return changelogPreamble & section
  let marker = existing.find("\n## ")
  if marker < 0:
    return existing.strip(leading = false, trailing = true) & "\n\n" & section
  let head = existing[0 ..< marker + 1].strip(leading = false, trailing = true)
  let tail = existing[marker + 1 .. ^1]
  head & "\n\n" & section & "\n" & tail
