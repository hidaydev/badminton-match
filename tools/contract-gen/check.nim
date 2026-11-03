## Verifies packages/contracts/openapi/CONTRACT.sha256 against the tree: both
## source specs, the merged document, and every generated output. Fails when a
## spec or a generated file changed without a recorded fingerprint update.

import std/[json, os, strutils, tables]

import emit_nim
import fingerprint

proc failNow(message: string) {.noreturn.} =
  stderr.writeLine "contract-check: " & message
  quit(1)

proc readSource(path: string): string =
  if not fileExists(path):
    failNow "missing " & path
  readFile(path)

proc parseSource(path, source: string): JsonNode =
  try:
    parseJson(source)
  except JsonParsingError as error:
    failNow path & ": " & error.msg

proc operationCount(core, community: JsonNode): int =
  var operations = collectOperations(core, corePath)
  operations.add(collectOperations(community, communityPath))
  operations.len

proc recordedOperations(recorded: string): string =
  for rawLine in recorded.splitLines:
    let line = rawLine.strip()
    if line.startsWith("operations "):
      return line["operations ".len .. ^1].strip()
  ""

proc main() =
  for argument in commandLineParams():
    case argument
    of "--help":
      echo "Usage: contract-check"
      echo "Verifies " & fingerprintPath & " against the specs and generated files."
      quit(0)
    else:
      failNow "unknown argument: " & argument

  if not fileExists(fingerprintPath):
    failNow "missing " & fingerprintPath & "; run ./task contract-gen"

  let recordedSource = readSource(fingerprintPath)
  let coreSource = readSource(corePath)
  let communitySource = readSource(communityPath)
  let core = parseSource(corePath, coreSource)
  let community = parseSource(communityPath, communitySource)
  let operations = operationCount(core, community)

  let expected = parseFingerprint(renderFingerprint(
    operations,
    coreSource,
    communitySource,
    readSource(mergedPath),
    readSource(nimPath),
    readSource(tsPath)))
  let recorded = parseFingerprint(recordedSource)

  var drifted: seq[string] = @[]

  let recordedCount = recordedOperations(recordedSource)
  if recordedCount.len == 0:
    drifted.add "  operations: not recorded (expected " & $operations & ")"
  elif recordedCount != $operations:
    drifted.add "  operations: recorded " & recordedCount & ", actual " &
      $operations

  var seen = initTable[string, bool]()
  for item in expected:
    seen[item.path] = true
    var found = ""
    for candidate in recorded:
      if candidate.path == item.path:
        found = candidate.digest
        break
    if found.len == 0:
      drifted.add "  " & item.kind & " " & item.path & ": not recorded (" &
        item.digest & ")"
    elif found != item.digest:
      drifted.add "  " & item.kind & " " & item.path & ": recorded " & found &
        ", actual " & item.digest
  for candidate in recorded:
    if not seen.hasKey(candidate.path):
      drifted.add "  " & candidate.kind & " " & candidate.path &
        ": recorded but no longer part of the contract"

  if drifted.len > 0:
    stderr.writeLine "contract-check: " & fingerprintPath & " is stale"
    for line in drifted:
      stderr.writeLine line
    stderr.writeLine "run ./task contract-gen and review " & fingerprintPath &
      " (procedure: packages/contracts/openapi/README.md)"
    quit(1)

  echo "contract-check: ok (" & $operations & " operations, " &
    $expected.len & " fingerprint entries)"

when isMainModule:
  main()
