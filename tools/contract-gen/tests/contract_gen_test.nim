import std/[json, os, osproc, sequtils, strtabs, strutils, unittest]

import ../emit_nim
import ../emit_ts
import ../fingerprint
import ../gen
import ../check as contractCheck

# Two of the behaviours under test end the process instead of returning a value
# (`cli.fail` and the drift `quit`), so the suite re-executes its own binary for
# them. The probe travels in the environment, never in the arguments, because
# `check.main` treats every argument as a flag.
const probeVariable = "CONTRACT_GEN_TEST_PROBE"

proc probeEnv(value: string): StringTableRef =
  result = newStringTable(modeCaseSensitive)
  for (key, item) in envPairs():
    result[key] = item
  result[probeVariable] = value

proc selfRun(probe: string, args: seq[string] = @[], dir = ""):
    tuple[output: string, exitCode: int] =
  var binary = getAppFilename()
  if not binary.isAbsolute:
    binary = getCurrentDir() / binary
  var command = quoteShell(binary)
  for argument in args:
    command.add " " & quoteShell(argument)
  execCmdEx(command, env = probeEnv(probe), workingDir = dir)

when isMainModule:
  case getEnv(probeVariable)
  of "merge-duplicate":
    # Two specs claiming the same path is the merge's only refusal.
    discard mergeDocs(
      parseJson("""{"servers": [], "components": {}, "paths": {"/dup": {"get": {"operationId": "a"}}}}"""),
      parseJson("""{"paths": {"/dup": {"get": {"operationId": "b"}}}}"""))
    quit(0)
  of "check":
    contractCheck.main()
    quit(0)
  else:
    discard

# --- TL-02: fingerprint ------------------------------------------------------

suite "fingerprint render":
  test "the spec group comes first and each group is sorted by path":
    let rendered = renderFingerprint(3, "core", "community", "merged", "nim", "ts")
    let entries = parseFingerprint(rendered)
    check entries.len == 5
    check entries[0].kind == "spec"
    check entries[1].kind == "spec"
    check entries[0].path == "packages/contracts/openapi/community.yaml"
    check entries[1].path == "packages/contracts/openapi/core.yaml"
    check entries[2].kind == "generated"
    check entries[3].kind == "generated"
    check entries[4].kind == "generated"
    check entries[2].path == "apps/api/src/routes_gen.nim"
    check entries[3].path == "packages/contracts/openapi/api.yaml"
    check entries[4].path == "packages/web-client/src/api.ts"
    check rendered.startsWith("# Majadu contract fingerprint")
    check rendered.contains("\nformat 1\noperations 3\n")

  test "one changed byte in a source changes exactly one digest":
    let baseline = parseFingerprint(
      renderFingerprint(2, "aa", "bb", "cc", "dd", "ee"))
    let mutations = [
      (corePath, renderFingerprint(2, "ab", "bb", "cc", "dd", "ee")),
      (communityPath, renderFingerprint(2, "aa", "bc", "cc", "dd", "ee")),
      (mergedPath, renderFingerprint(2, "aa", "bb", "cd", "dd", "ee")),
      (nimPath, renderFingerprint(2, "aa", "bb", "cc", "de", "ee")),
      (tsPath, renderFingerprint(2, "aa", "bb", "cc", "dd", "ef"))]
    for (expectedPath, text) in mutations:
      let changed = parseFingerprint(text)
      check changed.len == baseline.len
      var differing: seq[string] = @[]
      for index in 0 ..< baseline.len:
        check changed[index].path == baseline[index].path
        if changed[index].digest != baseline[index].digest:
          differing.add changed[index].path
      check differing == @[expectedPath]

  test "a digest is a sha256 hex of the source it names":
    let entries = parseFingerprint(renderFingerprint(1, "core", "c", "m", "n", "t"))
    check entries.len == 5
    for item in entries:
      check item.digest.len == 64
      check item.digest == item.digest.toLowerAscii

suite "fingerprint parse":
  const sampleDigest =
    "0000000000000000000000000000000000000000000000000000000000000000"

  test "comments, the format line, blank lines and short lines are ignored":
    let content = "# a comment\n\n   \nformat 1\nspec core.yaml\n" &
      "spec packages/contracts/openapi/core.yaml " & sampleDigest & "\n"
    let entries = parseFingerprint(content)
    check entries.len == 1
    check entries[0].kind == "spec"
    check entries[0].path == "packages/contracts/openapi/core.yaml"
    check entries[0].digest == sampleDigest

  test "a rendered fingerprint round-trips":
    let rendered = renderFingerprint(5, "core", "community", "merged", "nim", "ts")
    var rebuilt = ""
    for item in parseFingerprint(rendered):
      rebuilt.add item.kind & " " & item.path & " " & item.digest & "\n"
    check rebuilt.len > 0
    check rendered.endsWith(rebuilt)

  test "a path that contains spaces survives":
    let entries = parseFingerprint(
      "generated docs/some dir/a b.sql " & sampleDigest & "\n")
    check entries.len == 1
    check entries[0].path == "docs/some dir/a b.sql"
    check entries[0].digest == sampleDigest

# --- TL-02: emitters ---------------------------------------------------------

proc sampleDocument(): JsonNode =
  parseJson("""
{
  "paths": {
    "/ws/room": {"get": {"operationId": "wsRoom", "x-websocket": {}}},
    "/sessions": {
      "post": {"operationId": "createSession", "tags": ["session"],
               "requestBody": {"required": true}},
      "options": {"operationId": "optionsSession"}
    },
    "/healthz": {"get": {"operationId": "healthz"}},
    "/c/{slug}/members": {
      "get": {"operationId": "communityMembers", "tags": ["community"],
              "parameters": [{"name": "slug", "in": "path"},
                             {"name": "q", "in": "query"}]}
    }
  }
}
""")

suite "collectOperations":
  test "paths are sorted and unknown verbs are skipped":
    let operations = collectOperations(sampleDocument(), "core.yaml")
    check operations.len == 4
    check operations.mapIt(it.path) == @["/c/{slug}/members", "/healthz",
      "/sessions", "/ws/room"]
    check operations.allIt(it.httpMethod != "OPTIONS")
    check operations.allIt(it.operationId != "optionsSession")

  test "only path parameters are recorded":
    let operations = collectOperations(sampleDocument(), "core.yaml")
    let members = operations[0]
    check members.operationId == "communityMembers"
    check members.httpMethod == "GET"
    check members.tag == "community"
    check members.pathParams == @["slug"]
    check not members.hasBody
    check not members.isWebSocket

  test "a request body and a websocket extension are recorded":
    let operations = collectOperations(sampleDocument(), "core.yaml")
    let create = operations[2]
    check create.httpMethod == "POST"
    check create.hasBody
    check create.tag == "session"
    check create.pathParams.len == 0
    let socket = operations[3]
    check socket.isWebSocket
    check not socket.hasBody
    check socket.tag == ""

  test "a missing operationId raises":
    expect ValueError:
      discard collectOperations(parseJson("""{"paths": {"/x": {"get": {}}}}"""),
        "spec.yaml")

  test "a document without paths raises":
    expect ValueError:
      discard collectOperations(parseJson("""{}"""), "spec.yaml")

  test "sortOperations orders by path then method":
    var operations = @[
      Operation(operationId: "post", httpMethod: "POST", path: "/sessions"),
      Operation(operationId: "get", httpMethod: "GET", path: "/sessions"),
      Operation(operationId: "health", httpMethod: "GET", path: "/healthz")]
    sortOperations(operations)
    check operations.mapIt(it.operationId) == @["health", "get", "post"]

suite "renderNim":
  test "quotes, backslashes and newlines in a pathParams list are escaped":
    let operation = Operation(
      operationId: "odd", httpMethod: "GET", path: "/odd", tag: "tag",
      pathParams: @["a\"b", "c\\d", "e\nf"], hasBody: true, isWebSocket: false)
    let rendered = renderNim(@[operation])
    check rendered.contains("pathParams: \"a\\\"b,c\\\\d,e\\nf\"")
    check rendered.contains("hasBody: true")
    check rendered.contains("isWebSocket: false")
    check rendered.contains("routeCount* = 1")

  test "flags render as Nim booleans and the count follows the list":
    let operations = @[
      Operation(operationId: "a", httpMethod: "GET", path: "/a"),
      Operation(operationId: "b", httpMethod: "GET", path: "/b",
        isWebSocket: true)]
    let rendered = renderNim(operations)
    check rendered.contains("hasBody: false")
    check rendered.contains("isWebSocket: true")
    check rendered.contains("routeCount* = 2")

suite "renderTs":
  test "no path parameters render as an empty array":
    let operation = Operation(
      operationId: "plain", httpMethod: "GET", path: "/plain", tag: "")
    let rendered = renderTs(@[operation])
    check rendered.contains("pathParams: [],")
    check rendered.contains("hasBody: false")

  test "one quoted entry per path parameter":
    let operation = Operation(
      operationId: "pair", httpMethod: "GET", path: "/pair/{a}/{b}", tag: "pair",
      pathParams: @["a", "b"])
    let rendered = renderTs(@[operation])
    check rendered.contains("pathParams: [\"a\", \"b\"],")

suite "mergeDocs":
  test "the merged document keeps both paths, sorted":
    let core = parseJson("""{"servers": [{"url": "/"}], "components": {},
      "paths": {"/b": {"get": {"operationId": "b"}}}}""")
    let community = parseJson(
      """{"paths": {"/a": {"post": {"operationId": "a"}}}}""")
    let merged = mergeDocs(core, community)
    check toSeq(merged["paths"].keys) == @["/a", "/b"]
    check merged["openapi"].getStr() == "3.1.0"
    check merged["servers"][0]["url"].getStr() == "/"

  test "a duplicate path across the two specs is refused":
    let run = selfRun("merge-duplicate")
    check run.exitCode == 1
    check run.output.contains("duplicate path across specs: /dup")

suite "writeOrCheck":
  var dir: string

  setup:
    dir = getTempDir() / "contract-gen-write"
    if dirExists(dir):
      removeDir(dir)
    createDir(dir)

  teardown:
    if dirExists(dir):
      removeDir(dir)

  test "a missing file fails the check":
    check not writeOrCheck(dir / "missing.txt", "body", true)

  test "different content fails the check":
    writeFile(dir / "f.txt", "old")
    check not writeOrCheck(dir / "f.txt", "new", true)

  test "identical content passes the check":
    writeFile(dir / "f.txt", "same")
    check writeOrCheck(dir / "f.txt", "same", true)

  test "write mode creates the parent directory and the file":
    let target = dir / "nested" / "deep" / "f.txt"
    check writeOrCheck(target, "body", false)
    check readFile(target) == "body"

# --- TL-03: the drift reporter ----------------------------------------------

const
  coreSpec = """{
  "openapi": "3.1.0",
  "servers": [{"url": "/"}],
  "components": {},
  "paths": {"/healthz": {"get": {"operationId": "healthz"}}}
}
"""
  communitySpec = """{
  "openapi": "3.1.0",
  "paths": {"/c/{slug}/members": {"get": {"operationId": "communityMembers"}}}
}
"""
  mergedText = "{}\n"
  nimSource = "const routes* = []\n"
  tsSource = "export const routes = [];\n"

proc writeCheckTree(root: string) =
  ## A complete contract tree under `root`: the two specs, the merged document,
  ## both generated files and a fingerprint that matches all of them.
  let openapi = root / "packages/contracts/openapi"
  createDir(openapi)
  createDir(root / "packages/web-client/src")
  createDir(root / "apps/api/src")
  writeFile(openapi / "core.yaml", coreSpec)
  writeFile(openapi / "community.yaml", communitySpec)
  writeFile(openapi / "api.yaml", mergedText)
  writeFile(openapi / "CONTRACT.sha256", renderFingerprint(2, coreSpec,
    communitySpec, mergedText, nimSource, tsSource))
  writeFile(root / "apps/api/src/routes_gen.nim", nimSource)
  writeFile(root / "packages/web-client/src/api.ts", tsSource)

suite "contract-check drift":
  var root: string

  setup:
    root = getTempDir() / "contract-gen-check"
    if dirExists(root):
      removeDir(root)
    createDir(root)
    writeCheckTree(root)

  teardown:
    if dirExists(root):
      removeDir(root)

  test "an unmodified tree passes and counts the operations":
    let run = selfRun("check", @[], root)
    check run.exitCode == 0
    check run.output.contains("contract-check: ok (2 operations, 5 fingerprint entries)")

  test "one edited spec byte is reported against that spec path":
    writeFile(root / corePath, coreSpec & " ")
    let run = selfRun("check", @[], root)
    check run.exitCode == 1
    check run.output.contains(corePath & ": recorded ")
    check run.output.contains("is stale")

  test "a deleted recorded entry is reported as not recorded":
    let target = root / fingerprintPath
    var kept: seq[string] = @[]
    for line in readFile(target).splitLines():
      if not line.contains(tsPath):
        kept.add line
    writeFile(target, kept.join("\n") & "\n")
    let run = selfRun("check", @[], root)
    check run.exitCode == 1
    check run.output.contains(tsPath & ": not recorded")

  test "an extra recorded entry is reported as outside the contract":
    let target = root / fingerprintPath
    writeFile(target, readFile(target) &
      "generated packages/web-client/src/extra.ts " & repeat('0', 64) & "\n")
    let run = selfRun("check", @[], root)
    check run.exitCode == 1
    check run.output.contains(
      "packages/web-client/src/extra.ts: recorded but no longer part of the contract")

  test "a changed operations line is reported as a count mismatch":
    let target = root / fingerprintPath
    writeFile(target, readFile(target).replace("operations 2", "operations 9"))
    let run = selfRun("check", @[], root)
    check run.exitCode == 1
    check run.output.contains("operations: recorded 9, actual 2")

  test "an unknown argument exits 2":
    let run = selfRun("check", @["--bogus"], root)
    check run.exitCode == 2
    check run.output.contains("unknown argument: --bogus")

  test "--help exits 0 with the usage line":
    let run = selfRun("check", @["--help"], root)
    check run.exitCode == 0
    check run.output.contains("Usage: contract-check")
suite "query parameters":
  test "travel into the Nim route table and the TypeScript client":
    let operation = Operation(operationId: "list", httpMethod: "GET",
      path: "/list", tag: "", queryParams: @["limit", "offset"])
    check renderNim(@[operation]).contains("queryParams: \"limit,offset\",")
    check renderTs(@[operation]).contains("queryParams: [\"limit\", \"offset\"],")

  test "an operation without a query renders an empty list":
    let operation = Operation(operationId: "one", httpMethod: "GET",
      path: "/one", tag: "")
    check renderNim(@[operation]).contains("queryParams: \"\",")
    check renderTs(@[operation]).contains("queryParams: [],")

suite "request keys":
  test "request body properties become the operation's keys, sorted":
    let doc = parseJson("""{
      "paths": {
        "/x": {
          "post": {
            "operationId": "createX",
            "requestBody": {
              "content": {
                "application/json": {
                  "schema": {
                    "type": "object",
                    "properties": {
                      "b": {"type": "string"},
                      "a": {"type": "integer"}
                    }
                  }
                }
              }
            }
          }
        }
      }
    }""")
    let operations = collectOperations(doc, "spec")
    check operations.len == 1
    check operations[0].requestKeys == @["a", "b"]

  test "a body behind a component reference resolves to its properties":
    let doc = parseJson("""{
      "paths": {"/x": {"post": {"operationId": "createX",
        "requestBody": {"content": {"application/json": {"schema":
          {"$ref": "#/components/schemas/CreateX"}}}}}}},
      "components": {"schemas": {"CreateX": {"type": "object",
        "properties": {"name": {"type": "string"}}}}}}""")
    let operations = collectOperations(doc, "spec")
    check operations[0].requestKeys == @["name"]

  test "a body with no properties declares no key":
    let doc = parseJson("""{"paths": {"/x": {"post": {"operationId": "createX",
      "requestBody": {"content": {"application/json": {"schema":
        {"type": "object"}}}}}}}}""")
    check collectOperations(doc, "spec")[0].requestKeys.len == 0

  test "the rendered route carries the keys and an empty body stays empty":
    let declared = Operation(operationId: "createX", httpMethod: "POST",
      path: "/x", requestKeys: @["name", "tier"])
    check renderNim(@[declared]).contains("requestKeys: \"name,tier\",")
    check renderTs(@[declared]).contains("requestKeys: [\"name\", \"tier\"],")
    let empty = Operation(operationId: "one", httpMethod: "GET", path: "/one")
    check renderNim(@[empty]).contains("requestKeys: \"\",")

suite "generated types":
  test "a schema becomes an interface with required and optional fields":
    let schemas = parseJson("""{"Member": {"type": "object",
      "required": ["userId", "role"],
      "properties": {"userId": {"type": "string"},
                     "role": {"enum": ["admin", "member"]},
                     "joinedAt": {"type": "string"}}}}""")
    let rendered = renderTs(@[], schemas)
    check rendered.contains("export interface Member {")
    check rendered.contains("  userId: string;")
    check rendered.contains("  role: \"admin\" | \"member\";")
    check rendered.contains("  joinedAt?: string;")

  test "an array and a reference keep their names":
    let schemas = parseJson("""{"Page": {"type": "object",
      "required": ["items"],
      "properties": {"items": {"type": "array",
                               "items": {"$ref": "#/components/schemas/Member"}}}}}""")
    let rendered = renderTs(@[], schemas)
    check rendered.contains("  items: Array<Member>;")

  test "a nullable field is a union with null":
    let schemas = parseJson("""{"Row": {"type": "object",
      "required": ["at"],
      "properties": {"at": {"type": ["string", "null"]}}}}""")
    check renderTs(@[], schemas).contains("  at: string | null;")

  test "schemas are sorted by name":
    let schemas = parseJson("""{"Zeta": {"type": "object", "properties": {}},
      "Alpha": {"type": "object", "properties": {}}}""")
    let rendered = renderTs(@[], schemas)
    check rendered.find("export interface Alpha") < rendered.find("export interface Zeta")
