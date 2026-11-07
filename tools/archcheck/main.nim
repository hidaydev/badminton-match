import std/[os, strutils]
import rules
import scan_constants

const roots = ["apps", "modules", "shared", "tools"]
const allowlistPath = "tools/archcheck/allowlist_constants.txt"

proc at(base, relative: string): string =
  ## `./task check` may be run from any directory; REPO_ROOT names the tree.
  base / relative

proc main() =
  let base = getEnv("REPO_ROOT", getCurrentDir())
  var violations: seq[string] = @[]
  var scanned = 0
  # The seed is what the database holds, so it is the reference the code must
  # not repeat and the bounds must match. A missing seed means a partial
  # checkout, not a clean tree: the guard fails instead of reporting a scan it
  # did not perform.
  let seedFile = at(base, seedPath)
  if not fileExists(seedFile):
    stderr.writeLine "archcheck: missing seed file: " & seedFile
    quit(1)
  let registryFile = at(base, registryPath)
  if not fileExists(registryFile):
    stderr.writeLine "archcheck: missing config registry: " & registryFile
    quit(1)
  let seedSql = readFile(seedFile)
  let values = seededValues(seedSql)
  let specs = registrySpecs(readFile(registryFile))
  let rows = seedRows(seedSql)
  # A parser that reads nothing would compare nothing and still print `ok`.
  if specs.len == 0 or rows.len == 0:
    stderr.writeLine "archcheck: no config keys read from " & registryPath &
      " / " & seedPath
    quit(1)
  violations.add(boundViolations(specs, rows))
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
