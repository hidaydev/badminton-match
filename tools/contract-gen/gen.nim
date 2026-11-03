import std/[algorithm, json, os, tables]
import emit_nim
import emit_ts

const
  corePath = "packages/contracts/openapi/core.yaml"
  communityPath = "packages/contracts/openapi/community.yaml"
  mergedPath = "packages/contracts/openapi/api.yaml"
  nimPath = "apps/api/src/routes_gen.nim"
  tsPath = "packages/web-client/src/api.ts"

proc fail(message: string) {.noreturn.} =
  stderr.writeLine "contract-gen: " & message
  quit(1)

proc load(path: string): JsonNode =
  if not fileExists(path):
    fail "missing " & path
  try:
    parseFile(path)
  except JsonParsingError as error:
    fail path & ": " & error.msg

proc mergeDocs(core, community: JsonNode): JsonNode =
  var paths = newJObject()
  var names: seq[string] = @[]
  for doc in [core, community]:
    if not doc.hasKey("paths"):
      fail "document has no paths"
    for path in doc["paths"].keys:
      if path in names:
        fail "duplicate path across specs: " & path
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

proc writeOrCheck(path, content: string, check: bool): bool =
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
      fail "unknown argument: " & argument

  let core = load(corePath)
  let community = load(communityPath)
  var operations = collectOperations(core, corePath)
  operations.add(collectOperations(community, communityPath))
  sortOperations(operations)
  if operations.len != 73:
    fail "expected 73 operations, found " & $operations.len

  var seen = initTable[string, bool]()
  for operation in operations:
    if seen.hasKeyOrPut(operation.operationId, true):
      fail "duplicate operationId: " & operation.operationId

  let merged = mergeDocs(core, community)
  var ok = true
  ok = writeOrCheck(mergedPath, renderJson(merged), check) and ok
  ok = writeOrCheck(nimPath, renderNim(operations), check) and ok
  ok = writeOrCheck(tsPath, renderTs(operations), check) and ok
  if not ok:
    fail "generated files differ; run ./task contract-gen"
  if check:
    echo "contract-gen: ok (" & $operations.len & " operations)"
  else:
    echo "contract-gen: wrote " & $operations.len & " operations"

when isMainModule:
  main()
