import std/[os, strutils]
import rules
import scan_constants

const roots = ["apps", "modules", "shared", "tools"]
# A walker that visits nothing compares nothing and still prints `ok`. The floor
# is far below the tree (177 files today) but far above an empty or broken scan.
const minScannedFiles = 50
const allowlistPath = "tools/archcheck/allowlist_constants.txt"
# Statements that touch a domain table without a community predicate and are
# platform-level by design; each entry carries its reason.
const communityAllowlistPath = "tools/archcheck/allowlist_community.txt"
# QA-02: test blocks the honest-test scan lets through; each entry carries the
# reason the audit recorded, so the exemption is visible rather than implied.
const honestAllowlistPath = "tools/archcheck/allowlist_tests.txt"

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
  let communityAllowed =
    if fileExists(at(base, communityAllowlistPath)):
      loadAllowlist(readFile(at(base, communityAllowlistPath)))
    else: @[]
  let honestAllowed =
    if fileExists(at(base, honestAllowlistPath)):
      loadAllowlist(readFile(at(base, honestAllowlistPath)))
    else: @[]
  # Test blocks are judged after the walk, because a block that delegates its
  # assertion to a helper needs that helper's name, which any file can declare.
  var asserting: seq[string] = @[]
  var testSources: seq[(string, string)] = @[]
  for root in roots:
    let directory = at(base, root)
    if not dirExists(directory):
      continue
    for absolute in walkDirRec(directory):
      let path = absolute.replace(base & "/", "")
      if not path.endsWith(".nim"):
        continue
      # The tree is skipped whole, including its tests. The fixtures in
      # `tests/archcheck_test.nim` are violation shapes written as string
      # literals, so scanning them would report the rule examples as findings.
      if path.startsWith("tools/archcheck/"):
        continue
      scanned.inc
      let source = readFile(absolute)
      violations.add(violationsFor(path, source, communityAllowed))
      if not path.contains("/tests/") and not path.endsWith("_gen.nim"):
        violations.add(constantViolations(path, source, values, allowed))
      for name in assertingRoutines(source):
        if name notin asserting:
          asserting.add(name)
      if path.endsWith("_test.nim"):
        testSources.add((path, source))
  for (path, source) in testSources:
    violations.add(honestTestViolations(path, source, honestAllowed, asserting))
  for violation in violations:
    stderr.writeLine "archcheck: " & violation
  if violations.len > 0:
    stderr.writeLine "archcheck: " & $violations.len & " violation(s)"
    quit(1)
  if scanned < minScannedFiles:
    stderr.writeLine "archcheck: " & scanFloorViolation(scanned, minScannedFiles)
    quit(1)
  echo "archcheck: ok (" & $scanned & " files)"

when isMainModule:
  main()
