## QA-06: the mutation manifest must cover every module that owns a write path
## or an access decision. A manifest entry whose file or suite disappeared is a
## silent no-op, so both are checked here as well.

import std/[os, strutils, unittest]

const repoDir = currentSourcePath().parentDir.parentDir.parentDir.parentDir

# The areas the audit named. Each must carry at least one mutant, even when the
# changed-prefix job happens to run only one of them.
const requiredAreas = [
  "apps/api/src/",
  "modules/session/",
  "modules/tournament/",
  "modules/player/",
  "modules/account/",
]

suite "mutation manifest":
  test "every write path or access decision area has a mutant":
    let manifest = readFile(repoDir / "tools" / "mutation" / "manifest.txt")
    var files: seq[string] = @[]
    for raw in manifest.splitLines():
      let line = raw.strip()
      if line.len == 0 or line.startsWith("#"):
        continue
      let fields = line.split(" | ")
      check fields.len == 5
      if fields.len == 5:
        files.add fields[1].strip()
    for area in requiredAreas:
      var found = false
      for file in files:
        if file.startsWith(area):
          found = true
      check found

  test "every entry names a file and a suite that exist":
    let manifest = readFile(repoDir / "tools" / "mutation" / "manifest.txt")
    for raw in manifest.splitLines():
      let line = raw.strip()
      if line.len == 0 or line.startsWith("#"):
        continue
      let fields = line.split(" | ")
      if fields.len != 5:
        continue
      let file = fields[1].strip()
      let suite = fields[2].strip()
      checkpoint(fields[0].strip())
      check fileExists(repoDir / file)
      check fileExists(repoDir / suite)
