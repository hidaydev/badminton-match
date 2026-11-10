## SEC-05: the release gate for the OSV report.
##
## `osv-scanner` exits 1 when it finds anything at all, so a raw exit code would
## block the pipeline on a moderate advisory in a transitive development
## dependency. The report is the verdict here instead: a finding at HIGH or
## CRITICAL stops the job, a finding whose severity the database does not name is
## treated the same way because a gate that cannot classify a result must not
## pass it, and the rest are counted and printed once.
##
## Input: the JSON report written by `osv-scanner scan source --format=json`.
## `task.d/osv-scan.sh` runs the scanner and then this checker; nothing else does.

import std/[json, os, strutils]

import cli

const
  program = "osvgate"
  ## The severity vocabulary the advisory database uses for GitHub advisories.
  blockingSeverities = ["HIGH", "CRITICAL"]

type
  Finding* = object
    ## Exported for the suite, which asserts on the fields instead of on the
    ## printed lines.
    severity*: string
    id*: string
    package*: string
    version*: string
    source*: string

proc text(node: JsonNode, key: string): string =
  if node.kind == JObject and node.hasKey(key) and node[key].kind == JString:
    node[key].getStr()
  else:
    ""

proc objectAt(node: JsonNode, key: string): JsonNode =
  if node.kind == JObject and node.hasKey(key) and node[key].kind == JObject:
    node[key]
  else:
    newJObject()

proc objects(node: JsonNode, key: string): seq[JsonNode] =
  if node.kind != JObject or not node.hasKey(key) or node[key].kind != JArray:
    return @[]
  for entry in node[key]:
    if entry.kind == JObject:
      result.add entry

proc severityOf(vulnerability: JsonNode): string =
  ## The named severity the advisory database carries. An advisory that only
  ## carries a CVSS vector is UNKNOWN, which blocks.
  let severity = text(objectAt(vulnerability, "database_specific"), "severity")
  if severity.len == 0:
    return "UNKNOWN"
  severity.toUpperAscii()

proc collect*(report: JsonNode): seq[Finding] =
  ## `results[].source.path` names the lockfile; the package and the advisory
  ## are nested under it. An empty report (no lockfile, no finding) is valid.
  for entry in objects(report, "results"):
    let source = text(objectAt(entry, "source"), "path")
    for package in objects(entry, "packages"):
      let identity = objectAt(package, "package")
      for vulnerability in objects(package, "vulnerabilities"):
        result.add Finding(
          severity: severityOf(vulnerability),
          id: text(vulnerability, "id"),
          package: text(identity, "name"),
          version: text(identity, "version"),
          source: source)

proc blockers*(findings: openArray[Finding]): seq[Finding] =
  ## Fail closed on an unnamed severity: a result the gate cannot classify is
  ## reported instead of being counted as harmless.
  for finding in findings:
    if finding.severity in blockingSeverities or finding.severity == "UNKNOWN":
      result.add finding

proc main*() =
  var reportPath = ""
  for argument in commandLineParams():
    case argument
    of "--help", "-h":
      echo "Usage: osvgate <osv-scanner-report.json>"
      echo "Fails when the report holds a HIGH or CRITICAL finding, or one whose"
      echo "severity the advisory database does not name."
      quit(0)
    else:
      if reportPath.len > 0:
        usageFail(program, "one report at a time")
      reportPath = argument
  if reportPath.len == 0:
    usageFail(program, "a report path is required")
  if not fileExists(reportPath):
    fail(program, "missing report: " & reportPath)

  var report: JsonNode
  try:
    report = parseFile(reportPath)
  except CatchableError as error:
    fail(program, reportPath & ": " & error.msg)

  let findings = collect(report)
  let found = blockers(findings)
  if found.len > 0:
    stderr.writeLine "osvgate: " & $found.len & " finding(s) at or above the " &
      "blocking threshold"
    for finding in found:
      stderr.writeLine "  " & finding.id & " (" & finding.severity.toLowerAscii() &
        ") " & finding.package & " " & finding.version & " " & finding.source
    stderr.writeLine "update the lockfile, or record a dated exception in the " &
      "scanner configuration (docs/handbook/deps-format.md)"
    quit(1)
  echo "osvgate: ok (" & $findings.len & " finding(s), none at high or critical)"

when isMainModule:
  main()
