import std/[os, strutils]
import rules

const roots = ["apps", "modules", "shared", "tools"]

proc main() =
  var violations: seq[string] = @[]
  var scanned = 0
  for root in roots:
    if not dirExists(root):
      continue
    for path in walkDirRec(root):
      if not path.endsWith(".nim"):
        continue
      if path.startsWith("tools/archcheck/"):
        continue
      scanned.inc
      violations.add(violationsFor(path, readFile(path)))
  for violation in violations:
    stderr.writeLine "archcheck: " & violation
  if violations.len > 0:
    stderr.writeLine "archcheck: " & $violations.len & " violation(s)"
    quit(1)
  echo "archcheck: ok (" & $scanned & " files)"

when isMainModule:
  main()
