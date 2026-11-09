import std/[json, os, osproc, sequtils, strtabs, strutils, unittest]

import ../main

# `lint` ends the process with the verdict it printed, so the floor case runs it
# in a child process. The probe travels in the environment so the argument list
# stays exactly what `parseArgs` expects.
const probeVariable = "PARITY_TEST_PROBE"

proc probeEnv(value: string): StringTableRef =
  result = newStringTable(modeCaseSensitive)
  for (key, item) in envPairs():
    result[key] = item
  result[probeVariable] = value

proc selfRun(args: seq[string]): tuple[output: string, exitCode: int] =
  var binary = getAppFilename()
  if not binary.isAbsolute:
    binary = getCurrentDir() / binary
  var command = quoteShell(binary)
  for argument in args:
    command.add " " & quoteShell(argument)
  execCmdEx(command, env = probeEnv("lint"))

when isMainModule:
  if getEnv(probeVariable) == "lint":
    main()
    quit(0)

suite "pathMatches":
  test "a templated segment matches any non-empty one":
    check pathMatches("/c/{slug}/members", "/c/club/members")
    check pathMatches("/c/{slug}/members", "/c/42/members")

  test "a different segment count does not match":
    check not pathMatches("/c/{slug}/members", "/c/members")
    check not pathMatches("/healthz", "/healthz/extra")

  test "an empty templated segment does not match":
    check not pathMatches("/c/{slug}/members", "/c//members")

  test "a literal segment must be equal":
    check not pathMatches("/c/{slug}/members", "/d/club/members")

  test "leading and trailing slashes are ignored":
    check pathMatches("/healthz/", "healthz")

suite "routePathTemplate":
  test "a known verb yields the template":
    check routePathTemplate("GET /healthz") == "/healthz"
    check routePathTemplate("post /sessions") == "/sessions"

  test "a non-verb yields an empty template":
    check routePathTemplate("/healthz") == ""
    check routePathTemplate("FETCH /healthz") == ""
    check routePathTemplate("") == ""

suite "corpus sources":
  var dir: string

  setup:
    dir = getTempDir() / "parity-lint"
    if dirExists(dir):
      removeDir(dir)
    createDir(dir)

  teardown:
    if dirExists(dir):
      removeDir(dir)

  test "operation ids are read in file order":
    let source = "const routes* = [\n" &
      "  RouteSpec(\n" &
      "    operationId: \"healthz\",\n" &
      "    path: \"/healthz\",\n" &
      "  ),\n" &
      "  RouteSpec(\n" &
      "    operationId: \"communityMembers\",\n" &
      "    path: \"/c/{slug}/members\",\n" &
      "  ),\n" &
      "]\n"
    writeFile(dir / "routes_gen.nim", source)
    check operationsFromSource(dir / "routes_gen.nim") == @["healthz",
      "communityMembers"]

  test "a malformed line is skipped":
    writeFile(dir / "routes_gen.nim", "operationId: \"unterminated\n" &
      "entry without the marker\noperationId: \"ok\"\n")
    check operationsFromSource(dir / "routes_gen.nim") == @["ok"]

  test "a missing source file yields no operations":
    check operationsFromSource(dir / "absent.nim").len == 0

  test "declared routes skip comments and blank lines":
    writeFile(dir / "routes.txt", "# frozen list\n\nGET /healthz\n   \n" &
      "POST /sessions\n")
    check routesFromSource(dir / "routes.txt") == @["GET /healthz",
      "POST /sessions"]

  test "a missing route list yields no routes":
    check routesFromSource(dir / "absent.txt").len == 0

proc lintOnce(document: JsonNode):
    tuple[route: string, problems: seq[string], rejected: int] =
  result.problems = @[]
  result.route = lintCase("case", document, result.problems, result.rejected)

proc validCase(status = 200; body: JsonNode = %"ok"): JsonNode =
  %*{
    "route": "GET /healthz",
    "request": {"method": "GET", "path": "/healthz"},
    "expect": {"status": status, "body": body}
  }

suite "lintCase":
  test "a complete case yields its route and no problem":
    let result = lintOnce(validCase())
    check result.route == "GET /healthz"
    check result.problems.len == 0
    check result.rejected == 0

  test "a 4xx case counts towards the rejected floor":
    let document = %*{
      "route": "GET /healthz",
      "request": {"method": "GET", "path": "/healthz"},
      "expect": {"status": 404,
        "body": {"code": "notFound", "i18nKey": "error.notFound", "status": 404}}
    }
    let result = lintOnce(document)
    check result.problems.len == 0
    check result.rejected == 1

  test "the legacy error body passes when the envelope rule is off":
    ## v1 answers 4xx with `{"error": ...}`, so the v1 corpus is linted without
    ## the problem+json rule; the v2 corpus keeps it.
    let document = %*{
      "route": "GET /healthz",
      "request": {"method": "GET", "path": "/healthz"},
      "expect": {"status": 401,
        "body": {"error": {"code": "unauthorized", "message": "missing"}}}
    }
    var problems: seq[string] = @[]
    var rejected = 0
    discard lintCase("case", document, problems, rejected, false)
    check problems.len == 0
    check rejected == 1
    discard lintCase("case", document, problems, rejected)
    check problems.len == 3

  test "a case without expect is rejected":
    let result = lintOnce(%*{"route": "GET /healthz"})
    check result.problems.len == 1
    check result.problems[0].contains("missing expect")

  test "a non-integer status is rejected":
    let document = %*{
      "route": "GET /healthz",
      "request": {"method": "GET", "path": "/healthz"},
      "expect": {"status": "ok", "body": "ok"}
    }
    let result = lintOnce(document)
    check result.problems.anyIt(it.contains("expect.status missing or not an integer"))

  test "an empty body without emptyBody is rejected":
    let result = lintOnce(validCase(204, %""))
    check result.problems.anyIt(it.contains("expect.body is empty"))

  test "emptyBody on a non-empty body is rejected":
    var document = validCase(200, %"hello")
    document["expect"]["emptyBody"] = %true
    let result = lintOnce(document)
    check result.problems.anyIt(it.contains("emptyBody is set but the body is not empty"))

  test "expectNim without expectedDivergence is rejected":
    var document = validCase()
    document["expectNim"] = %*{"status": 200}
    let result = lintOnce(document)
    check result.problems.anyIt(it.contains("expectNim without expectedDivergence"))

  test "a divergence without a reason or an owner is rejected":
    var document = validCase()
    document["expectNim"] = %*{"status": 200}
    document["expectedDivergence"] = %*{"reason": "  ", "owner": ""}
    let result = lintOnce(document)
    check result.problems.anyIt(it.contains("expectedDivergence.reason is empty"))
    check result.problems.anyIt(it.contains("expectedDivergence.owner is empty"))

  test "expectedDivergence without expectNim is rejected":
    var document = validCase()
    document["expectedDivergence"] = %*{"reason": "v1 differs", "owner": "ops"}
    let result = lintOnce(document)
    check result.problems.anyIt(it.contains("expectedDivergence without expectNim"))

  test "a missing request or route is rejected":
    var document = validCase()
    document.delete("request")
    document.delete("route")
    let result = lintOnce(document)
    check result.route.len == 0
    check result.problems.anyIt(it.contains("missing request"))
    check result.problems.anyIt(it.contains("route missing"))

suite "lintErrorEnvelope":
  test "a successful response is not inspected":
    var problems: seq[string] = @[]
    lintErrorEnvelope("case", 200, %*{"anything": true}, problems)
    check problems.len == 0

  test "a 4xx body without a string code is reported":
    var problems: seq[string] = @[]
    lintErrorEnvelope("case", 404, %*{"i18nKey": "error.notFound", "status": 404},
      problems)
    check problems.len == 1
    check problems[0].contains("no string code")

  test "a 4xx body without an i18nKey is reported":
    var problems: seq[string] = @[]
    lintErrorEnvelope("case", 404, %*{"code": "notFound", "status": 404},
      problems)
    check problems.len == 1
    check problems[0].contains("no i18nKey")

  test "an i18nKey outside the error namespace is reported":
    var problems: seq[string] = @[]
    lintErrorEnvelope("case", 400,
      %*{"code": "bad", "i18nKey": "ui.bad", "status": 400}, problems)
    check problems.len == 1
    check problems[0].contains("i18nKey is not error.<name>")

  test "a status that disagrees with the record is reported":
    var problems: seq[string] = @[]
    lintErrorEnvelope("case", 404,
      %*{"code": "notFound", "i18nKey": "error.notFound", "status": 400},
      problems)
    check problems.len == 1
    check problems[0].contains("status does not match expect.status")

  test "a complete envelope is accepted":
    var problems: seq[string] = @[]
    lintErrorEnvelope("case", 429,
      %*{"code": "rateLimited", "i18nKey": "error.rateLimited", "status": 429},
      problems)
    check problems.len == 0

  test "a non-object error body is left to the body check":
    var problems: seq[string] = @[]
    lintErrorEnvelope("case", 500, %"plain text error", problems)
    check problems.len == 0

suite "lint floor":
  var root: string

  setup:
    root = getTempDir() / "parity-floor"
    if dirExists(root):
      removeDir(root)
    createDir(root)

  teardown:
    if dirExists(root):
      removeDir(root)

  proc writeCorpus(target: string; rejected: int) =
    createDir(target)
    for index in 1 .. 10:
      let document =
        if index <= rejected:
          %*{
            "route": "GET /healthz",
            "request": {"method": "GET", "path": "/healthz"},
            "expect": {"status": 404,
              "body": {"code": "notFound", "i18nKey": "error.notFound",
                       "status": 404}}
          }
        else:
          validCase()
      writeFile(target / ("case-" & $index & ".json"), pretty(document) & "\n")

  test "10 cases with 3 rejections fail the 40 percent floor":
    let corpus = root / "low"
    writeCorpus(corpus, 3)
    let run = selfRun(@["lint", "--dir", corpus])
    check run.exitCode == 1
    check run.output.contains("status>=400=3 (30.0%)")
    check run.output.contains("minimum is 40%")

  test "10 cases with 5 rejections meet the floor":
    let corpus = root / "passing"
    writeCorpus(corpus, 5)
    let run = selfRun(@["lint", "--dir", corpus])
    check run.exitCode == 0
    check run.output.contains("status>=400=5 (50.0%)")
    check run.output.contains("parity: corpus ok")