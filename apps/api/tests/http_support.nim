import std/[httpclient, json, net, os, strutils, unittest, uri]
import mummy
import db/db
import ../src/app
import ../src/live
import account/infrastructure/oidc
import account/infrastructure/session_store
import platform/config/store
import rating/infrastructure/jobs
import share/crypto

# Callers write `testPort(18090)` in their const block and pass `HttpGet`/
# `HttpPost` to `call`, so both symbols travel with the harness instead of every
# suite importing the client itself.
export net.Port
export httpclient

const
  allowedOrigin* = "http://127.0.0.1:5173"
  keysJson* = """{"1":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="}"""
  firstTestPort* = 18090

# One base per HTTP suite, all from 18090 upward. Adding a suite takes the next
# free number here; reusing one fails only after the ten second startup poll,
# which then blames the server instead of the duplicate.
#   18090 ws_ticket   18091 community   18092 player    18093 claim
#   18094 session     18095 ops_token   18096 rankings  18097 readyz
#   18098 idor        18099 csrf        18100 oidc      18101 ratelimit
#   18102 tournament  18103 read_smoke  18108 be08_concurrency  18111 request_cost
proc testPort*(base: int): Port =
  doAssert base >= firstTestPort, "test ports start at 18090"
  Port(base)

type
  ServeArgs = object
    server: Server
    port: Port

  HttpResult* = object
    status*: int
    body*: string
    headers*: seq[(string, string)]

proc serveThread(args: ServeArgs) {.thread.} =
  try:
    args.server.serve(args.port, "127.0.0.1")
  except MummyError:
    discard

proc dsn*(): string = getEnv("MAJADU_PG_DSN")

proc hasDatabase*(): bool = dsn().len > 0

proc requireDatabase*() =
  ## A suite that cannot run must never look like a suite that passed. Since D-6
  ## `./task check` requires a database, so a missing DSN is always an error with
  ## the command that fixes it, never a silent exit 0.
  if hasDatabase():
    return
  raise newException(ValueError,
    "MAJADU_PG_DSN is not set: run ./task dev-db and export " &
    "MAJADU_PG_DSN=postgresql://$USER@127.0.0.1:5432/bm2_test")

proc call*(baseUrl: string, verb: HttpMethod, path: string, cookie = "",
           body = "", origin = allowedOrigin, ifMatch = "",
           extra: openArray[(string, string)] = [],
           maxRedirects = 5): HttpResult =
  ## One request shape for the whole suite. `origin = ""` deliberately omits
  ## the header so the CSRF cases can prove what a missing Origin does.
  let client = newHttpClient(timeout = 10000, maxRedirects = maxRedirects)
  defer: client.close()
  var headers = newHttpHeaders()
  if origin.len > 0:
    headers["Origin"] = origin
  if cookie.len > 0:
    headers["Cookie"] = "majadu_session=" & cookie
  if body.len > 0:
    headers["Content-Type"] = "application/json"
  if ifMatch.len > 0:
    headers["If-Match"] = ifMatch
  for (key, value) in extra:
    headers[key] = value
  let response = client.request(baseUrl & path, httpMethod = verb,
    headers = headers, body = body)
  result.status = response.code.int
  result.body = response.body
  for (key, value) in response.headers.pairs:
    result.headers.add((key, value))

proc header*(response: HttpResult, name: string): string =
  for (key, value) in response.headers:
    if key.toLowerAscii() == name.toLowerAscii():
      return value
  ""

proc json*(response: HttpResult): JsonNode =
  parseJson(response.body)

proc queryParam*(url, name: string): string =
  for (key, value) in decodeQuery(parseUri(url).query):
    if key == name:
      return value
  ""

proc expectStatus*(response: HttpResult, status: int) =
  checkpoint("status " & $response.status & " body " & response.body)
  check response.status == status

proc expectProblem*(response: HttpResult, status: int, code = "") =
  ## Every rejection uses the shared problem shape: status, code, detail.
  checkpoint("status " & $response.status & " body " & response.body)
  check response.status == status
  if response.status != status:
    return
  let body = parseJson(response.body)
  check body.kind == JObject
  check body.hasKey("status") and body["status"].getInt() == status
  check body.hasKey("code") and body["code"].kind == JString
  check body.hasKey("detail") and body["detail"].kind == JString
  if code.len > 0:
    check body["code"].getStr() == code

var runningApp: App

proc startServer*(app: App, port: Port, baseUrl: string,
                  websocket = false) =
  ## `websocket` keeps the live-channel suite on the same harness: it needs the
  ## WebSocket handler registered next to the HTTP one.
  runningApp = app
  install(app)
  let server =
    if websocket: newServer(handler(), websocketHandler(), workerThreads = 4)
    else: newServer(handler(), workerThreads = 4)
  var thread: Thread[ServeArgs]
  createThread(thread, serveThread, ServeArgs(server: server, port: port))
  var up = false
  for _ in 0 ..< 200:
    try:
      let client = newHttpClient(timeout = 1000)
      defer: client.close()
      if client.get(baseUrl & "/healthz").code.int == 200:
        up = true
        break
    except CatchableError:
      discard
    sleep(50)
  doAssert up, "api did not start on port " & $uint16(port) & " (" & baseUrl & ")"

proc newTestApp*(db: Db): App =
  newApp(db, OidcConfig(), loadKeyring(keysJson, "1"), newConfigCache(db))

proc waitForRatingJobs*(timeoutMs = 5000) =
  ## Waits for the in-process rating worker to drain. A route that moves the
  ## ledger or the badge shelf now queues that work, so a suite that reads the
  ## result calls this instead of sleeping for a guessed interval.
  doAssert not runningApp.isNil, "startServer was not called"
  if not runningApp.ratingJobs.waitIdle(timeoutMs):
    raise newException(ValueError,
      "rating worker did not drain within " & $timeoutMs & "ms")

proc identityLookups*(): int =
  ## Database lookups spent turning a session cookie into a user id. Random
  ## cookies must stop reaching that query once the pre-limit is spent.
  doAssert not runningApp.isNil, "startServer was not called"
  runningApp.identityLookups()

proc cleanupUsers*(db: Db, prefix: string) =
  discard db.execUpdate(
    """delete from account.sessions where user_id in
         (select id from platform.user where google_sub like $1)""",
    @[textParam(prefix)])
  discard db.execUpdate("delete from platform.user where google_sub like $1",
    @[textParam(prefix)])

proc cookieFor*(db: Db, userId: string): string =
  createSession(db, userId, 30)
