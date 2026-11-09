import std/[algorithm, json, os, tables]
import cli
import emit_nim
import emit_ts
import fingerprint

const program = "contract-gen"

proc load(path: string): string =
  if not fileExists(path):
    fail(program, "missing " & path)
  readFile(path)

proc parse(path, source: string): JsonNode =
  try:
    parseJson(source)
  except JsonParsingError as error:
    fail(program, path & ": " & error.msg)

# Exported for tools/contract-gen/tests (D-5, TL-02): the merge refusal and the
# write-or-check contract are the two branches the CI self-check never reaches.
proc mergeDocs*(core, community: JsonNode): JsonNode =
  var paths = newJObject()
  var names: seq[string] = @[]
  for doc in [core, community]:
    if not doc.hasKey("paths"):
      fail(program, "document has no paths")
    for path in doc["paths"].keys:
      if path in names:
        fail(program, "duplicate path across specs: " & path)
      names.add(path)
  names.sort()
  for path in names:
    var methods = newJObject()
    for doc in [core, community]:
      if doc["paths"].hasKey(path):
        for verb in ["get", "post", "put", "patch", "delete"]:
          if doc["paths"][path].hasKey(verb):
            methods[verb] = doc["paths"][path][verb]
    paths[path] = methods
  result = newJObject()
  result["openapi"] = %"3.1.0"
  result["info"] = %*{"title": "Majadu API", "version": "2.0.0"}
  result["x-generated"] = %"tools/contract-gen; do not edit"
  result["servers"] = core["servers"]
  result["paths"] = paths
  result["components"] = core["components"]

proc renderJson(node: JsonNode): string =
  pretty(node, indent = 2) & "\n"

proc writeOrCheck*(path, content: string, check: bool): bool =
  if check:
    if not fileExists(path):
      stderr.writeLine "contract-gen: missing generated file " & path
      return false
    if readFile(path) != content:
      stderr.writeLine "contract-gen: stale " & path
      return false
    return true
  createDir(path.parentDir)
  writeFile(path, content)
  true

proc main() =
  var check = false
  for argument in commandLineParams():
    case argument
    of "--check": check = true
    of "--help":
      echo "Usage: contract-gen [--check]"
      quit(0)
    else:
      usageFail(program, "unknown argument: " & argument)

  let coreSource = load(corePath)
  let communitySource = load(communityPath)
  let core = parse(corePath, coreSource)
  let community = parse(communityPath, communitySource)
  var operations = collectOperations(core, corePath)
  operations.add(collectOperations(community, communityPath))
  sortOperations(operations)
  if operations.len != 76:
    fail(program, "expected 76 operations, found " & $operations.len)

  var seen = initTable[string, bool]()
  for operation in operations:
    if seen.hasKeyOrPut(operation.operationId, true):
      fail(program, "duplicate operationId: " & operation.operationId)

  let mergedSource = renderJson(mergeDocs(core, community))
  let nimSource = renderNim(operations)
  let tsSource = renderTs(operations, core["components"]["schemas"])
  var ok = true
  ok = writeOrCheck(mergedPath, mergedSource, check) and ok
  ok = writeOrCheck(nimPath, nimSource, check) and ok
  ok = writeOrCheck(tsPath, tsSource, check) and ok
  ok = writeOrCheck(fingerprintPath, renderFingerprint(operations.len,
    coreSource, communitySource, mergedSource, nimSource, tsSource),
    check) and ok
  if not ok:
    fail(program, "generated files differ; run ./task contract-gen")
  if check:
    echo "contract-gen: ok (" & $operations.len & " operations)"
  else:
    echo "contract-gen: wrote " & $operations.len & " operations"

when isMainModule:
  main()
