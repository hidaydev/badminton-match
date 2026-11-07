import std/[httpclient, json, net, options, os, strutils, unittest, uri]
import mummy
import db/db
import sha256
import ../src/app
import ../src/live
import account/infrastructure/oidc
import account/infrastructure/session_store
import platform/config/store
import share/crypto

# Callers write `Port(18094)` in their const block and pass `HttpGet`/`HttpPost`
# to `call`, so both symbols travel with the harness instead of every suite
# importing the client itself.
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
#   18102 tournament
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
  ## A suite that cannot run must never look like a suite that passed. In
  ## integration mode a missing DSN is an error; otherwise the suite says one
  ## line on stderr and exits 0, so `./task check` still works without a
  ## database without implying it ran one.
  if hasDatabase():
    return
  if getEnv("INTEGRATION") == "1":
    raise newException(ValueError,
      "MAJADU_PG_DSN is required when INTEGRATION=1")
  stderr.writeLine(
    "not run: MAJADU_PG_DSN is not set (set INTEGRATION=1 to require it)")
  quit 0

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

proc startServer*(app: App, port: Port, baseUrl: string,
                  websocket = false) =
  ## `websocket` keeps the live-channel suite on the same harness: it needs the
  ## WebSocket handler registered next to the HTTP one.
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

proc cleanupCommunity*(db: Db, slug: string) =
  ## FK-safe order for every row a security test may create.
  const tables = [
    "rating.events", "rating.player_state", "rating.snapshots",
    "tournament.matches", "tournament.pairs", "tournament.tournaments",
    "session.games", "session.participants", "session.courts",
    "session.links", "session.sessions",
    "player.claims", "player.merge_log", "player.aliases", "achievement.earned",
    "player.players",
    "community.membership", "community.invite", "community.join_request",
    "community.settings",
  ]
  for table in tables:
    discard db.execUpdate(
      "delete from " & table &
      " where community_id in (select id from platform.community where slug = $1)",
      @[textParam(slug)])
  discard db.execUpdate("delete from platform.community where slug = $1",
    @[textParam(slug)])

proc cleanupUsers*(db: Db, prefix: string) =
  discard db.execUpdate(
    """delete from account.sessions where user_id in
         (select id from platform.user where google_sub like $1)""",
    @[textParam(prefix)])
  discard db.execUpdate("delete from platform.user where google_sub like $1",
    @[textParam(prefix)])

proc addUser*(db: Db, sub, email: string, owner = false): string =
  db.queryOne(
    """insert into platform.user
         (google_sub, email_hash, display_name, is_platform_owner)
       values ($1, $2, $3, $4) returning id""",
    @[textParam(sub), textParam(sha256Hex(email)), textParam(sub),
      boolParam(owner)]).get.get("id")

proc addMember*(db: Db, communityId, userId, role: string) =
  discard db.execUpdate(
    """insert into community.membership (community_id, user_id, role)
       values ($1::uuid, $2::uuid, $3)""",
    @[textParam(communityId), textParam(userId), textParam(role)])

proc makePlayer*(db: Db, communityId, name: string): string =
  db.queryOne(
    """insert into player.players (community_id, canonical_name, gender)
       values ($1::uuid, $2, 'M') returning id""",
    @[textParam(communityId), textParam(name)]).get.get("id")

proc makeSession*(db: Db, communityId, title: string): string =
  db.queryOne(
    """insert into session.sessions
         (community_id, title, session_date, start_time, slot_minutes,
          status, source)
       values ($1::uuid, $2, current_date, '18:00', 30, 'draft', 'manual')
       returning id""",
    @[textParam(communityId), textParam(title)]).get.get("id")

proc cookieFor*(db: Db, userId: string): string =
  createSession(db, userId, 30)
