import std/[os, strutils]
import rules
import scan_constants

const roots = ["apps", "modules", "shared", "tools"]
const seedPath = "db/seeds/platform_config.sql"
const allowlistPath = "tools/archcheck/allowlist_constants.txt"

proc at(base, relative: string): string =
  ## `./task check` may be run from any directory; REPO_ROOT names the tree.
  base / relative

proc main() =
  let base = getEnv("REPO_ROOT", getCurrentDir())
  var violations: seq[string] = @[]
  var scanned = 0
  # The seed is what the database holds, so it is the reference the code must
  # not repeat. A missing seed means a partial checkout, not a clean tree.
  let values =
    if fileExists(at(base, seedPath)): seededValues(readFile(at(base, seedPath)))
    else: @[]
  let allowed =
    if fileExists(at(base, allowlistPath)):
      loadAllowlist(readFile(at(base, allowlistPath)))
    else: @[]
  for root in roots:
    let directory = at(base, root)
    if not dirExists(directory):
      continue
    for absolute in walkDirRec(directory):
      let path = absolute.replace(base & "/", "")
      if not path.endsWith(".nim"):
        continue
      if path.startsWith("tools/archcheck/"):
        continue
      scanned.inc
      let source = readFile(absolute)
      violations.add(violationsFor(path, source))
      if not path.contains("/tests/") and not path.endsWith("_gen.nim"):
        violations.add(constantViolations(path, source, values, allowed))
  for violation in violations:
    stderr.writeLine "archcheck: " & violation
  if violations.len > 0:
    stderr.writeLine "archcheck: " & $violations.len & " violation(s)"
    quit(1)
  echo "archcheck: ok (" & $scanned & " files)"

when isMainModule:
  main()
