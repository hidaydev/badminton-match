import std/[httpclient, json, os, strutils]
import normalizer

const casesDir = "testdata/parity/v2"

proc fail(message: string) {.noreturn.} =
  stderr.writeLine "parity: " & message
  quit(1)

proc request(client: HttpClient, verb, url: string, body: string): (int, string) =
  var response: Response
  case verb
  of "GET": response = client.request(url, httpMethod = HttpGet)
  of "POST": response = client.request(url, httpMethod = HttpPost, body = body)
  of "PUT": response = client.request(url, httpMethod = HttpPut, body = body)
  of "PATCH": response = client.request(url, httpMethod = HttpPatch, body = body)
  of "DELETE": response = client.request(url, httpMethod = HttpDelete)
  else: fail "unsupported method: " & verb
  (response.code.int, response.body)

proc parseArgs(): tuple[command, base, name, verb, path, body: string] =
  if paramCount() < 1:
    fail "usage: parity record|replay --base URL --name NAME [--method M] [--path P] [--body B]"
  result.command = paramStr(1)
  result.verb = "GET"
  var index = 2
  while index <= paramCount():
    case paramStr(index)
    of "--base":
      index.inc; result.base = paramStr(index)
    of "--name":
      index.inc; result.name = paramStr(index)
    of "--method":
      index.inc; result.verb = paramStr(index)
    of "--path":
      index.inc; result.path = paramStr(index)
    of "--body":
      index.inc; result.body = paramStr(index)
    else:
      fail "unknown argument: " & paramStr(index)
    index.inc
  if result.base.len == 0 or result.name.len == 0:
    fail "--base and --name are required"

proc record(base, name, verb, path, body: string) =
  var client = newHttpClient(timeout = 10000)
  defer: client.close()
  let (status, responseBody) = request(client, verb, base & path, body)
  var document = %*{
    "method": verb,
    "path": path,
    "status": status,
    "body": normalizeText(responseBody),
  }
  try:
    document["body"] = normalizeJson(parseJson(responseBody))
  except JsonParsingError:
    discard
  createDir(casesDir)
  let target = casesDir / (name & ".json")
  writeFile(target, pretty(document, indent = 2) & "\n")
  echo "parity: recorded " & target

proc replay(base, name, verb, path, body: string) =
  let target = casesDir / (name & ".json")
  if not fileExists(target):
    fail "case not found: " & target
  let expected = parseFile(target)
  let expectedMethod = expected["method"].getStr()
  let expectedPath = expected["path"].getStr()
  var client = newHttpClient(timeout = 10000)
  defer: client.close()
  let (status, responseBody) = request(
    client,
    if verb == "GET" and expectedMethod.len > 0: expectedMethod else: verb,
    base & (if path.len > 0: path else: expectedPath),
    body,
  )
  var problems: seq[string] = @[]
  if status != expected["status"].getInt():
    problems.add("status: expected " & $expected["status"].getInt() & ", got " & $status)
  var actual: JsonNode
  try:
    actual = normalizeJson(parseJson(responseBody))
  except JsonParsingError:
    actual = %normalizeText(responseBody)
  if actual != expected["body"]:
    problems.add("body differs")
  if problems.len > 0:
    for problem in problems:
      stderr.writeLine "parity: " & problem
    stderr.writeLine "  case: " & target
    quit(1)
  echo "parity: ok " & name

proc main() =
  let args = parseArgs()
  case args.command
  of "record": record(args.base, args.name, args.verb, args.path, args.body)
  of "replay": replay(args.base, args.name, args.verb, args.path, args.body)
  else: fail "unknown command: " & args.command

when isMainModule:
  main()
