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

  test "no exception text becomes a detail":
    for line in readFile(source).splitLines():
      if line.contains("problem(") and line.contains("error.msg"):
        checkpoint(line)
        check false

  test "the builder is the shared one":
    let text = readFile(source)
    check text.contains("sendProblem(request, status, \"application/problem+json\"")
    check text.contains("platformErrors.newProblem(status, code,")