import std/[json, os, strutils, unittest]
import errors

const source = currentSourcePath().parentDir / ".." / "src" / "app.nim"

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