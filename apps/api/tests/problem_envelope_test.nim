import std/[json, os, strutils, unittest]
import errors

const source = currentSourcePath().parentDir / ".." / "src" / "app.nim"
const reachability =
  currentSourcePath().parentDir / "integration" / "problem_codes_http_test.nim"

proc quotedCodes(text: string): seq[string] =
  ## Every string literal in the reachability suite. A code literal is the only
  ## shape made of upper-case letters and underscores, so the same scan picks up
  ## both a `requireRow(..., "CODE", ...)` argument and the `unreachable` list.
  var index = 0
  while true:
    let opening = text.find('"', index)
    if opening < 0:
      break
    let closing = text.find('"', opening + 1)
    if closing < 0:
      break
    let value = text[opening + 1 ..< closing]
    var codeLike = value.len > 0
    for character in value:
      if character notin {'A' .. 'Z', '_'}:
        codeLike = false
    if codeLike:
      result.add(value)
    index = closing + 1

proc problemCodes(): seq[string] =
  ## One quoted code per `problem(request, ...)` call. The declaration itself
  ## carries no code literal, so it is skipped.
  for line in readFile(source).splitLines():
    let marker = line.find("problem(request")
    if marker < 0:
      continue
    let quoted = line.find('"', marker)
    if quoted < 0:
      continue
    let closing = line.find('"', quoted + 1)
    if closing > quoted:
      result.add(line[quoted + 1 ..< closing])

suite "problem envelope":
  test "keeps the fields the web client reads":
    let node = parseJson(newProblem(400, "INVALID_BODY",
      i18nKeyFor("INVALID_BODY")).toJson())
    check node["status"].getInt() == 400
    check node["code"].getStr() == "INVALID_BODY"
    check node["i18nKey"].getStr() == "error.invalidBody"
    check node["detail"].getStr() == ""

  test "every problem code has a translation key":
    let codes = problemCodes()
    check codes.len > 0
    for code in codes:
      checkpoint(code)
      check i18nKeyFor(code) != unknownI18nKey

  test "codes passed through a variable reach the table":
    # `respondGate` forwards `codeFor(decision)` and the set-score path forwards
    # a `code` chosen in a branch; neither is a literal the scanner can see.
    # The pre-envelope 410/503 paths are literals again, but they are listed
    # here too so a future refactor cannot make them escape the table.
    for code in ["UNAUTHENTICATED", "FORBIDDEN", "NOT_FOUND",
                 "INVALID_SCORE", "INVALID_SET_SEQUENCE",
                 "CLIENT_OUTDATED", "NOT_READY"]:
      checkpoint(code)
      check i18nKeyFor(code) != unknownI18nKey

  test "validation detail keeps the parser's own message":
    # These parsers raise hand-written validation text, not provider text, and
    # the legacy UI renders `detail` verbatim.
    let text = readFile(source)
    check text.contains(
      "problem(request, 400, \"INVALID_BODY\", error.msg)")
    check text.contains(
      "problem(request, 400, \"INVALID_PATCH\", error.msg)")

  test "provider text stays out of the envelope":
    let text = readFile(source)
    check text.contains(
      "problem(request, 400, \"TOKEN_EXCHANGE_FAILED\", \"token exchange failed\")")
    check text.contains(
      "problem(request, 401, \"INVALID_ID_TOKEN\", \"id token is invalid\")")

  test "the builder is the shared one":
    let text = readFile(source)
    check text.contains("sendProblem(request, status, \"application/problem+json\"")
    check text.contains("platformErrors.newProblem(status, code,")

  test "every problem code has a reachability row":
    # A new `problem(request, ..., "CODE", ...)` branch must land with a case
    # in the table, or with a recorded reason in its `unreachable` list. The
    # table is the integration suite; this guard reads its two lists, because
    # importing that file would boot a server inside this unit suite.
    let table = readFile(reachability)
    let rows = quotedCodes(table)
    check rows.len > 60
    var missing: seq[string] = @[]
    for code in problemCodes():
      if code.len == 0 or code[0] notin {'A' .. 'Z'}:
        continue
      if code notin rows:
        missing.add(code)
    checkpoint("codes with no row: " & $missing)
    check missing.len == 0