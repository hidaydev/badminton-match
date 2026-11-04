import std/[httpclient, json, options, os, strutils, unittest]
import ws_client
import mummy
import db/db
import sha256
import ../../src/app
import ../../src/live
import account/infrastructure/oidc
import account/infrastructure/session_store
import platform/config/store
import share/crypto
import share/store as shareStore

const
  baseUrl = "http://127.0.0.1:18093"
  wsBase = "ws://127.0.0.1:18093"
  port = Port(18093)
  keysJson = """{"1":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="}"""
  allowedOrigin = "http://127.0.0.1:5173"

type
  ServeArgs = object
    server: Server
    port: Port

proc serveThread(args: ServeArgs) {.thread.} =
  try:
    args.server.serve(args.port, "127.0.0.1")
  except MummyError:
    discard

var
  database: Db
  keyring: Keyring
  userId, communityId, sessionId, foreignSessionId: string
  cookie, shareCode: string
  ttl: int

proc dsn(): string = getEnv("MAJADU_PG_DSN")

proc call(verb: HttpMethod, path: string, cookie = "",
          origin = allowedOrigin): (int, string) =
  let client = newHttpClient(timeout = 5000)
  defer: client.close()
  var headers = newHttpHeaders()
  if cookie.len > 0:
    headers["Cookie"] = "majadu_session=" & cookie
  if origin.len > 0:
    headers["Origin"] = origin
  let response = client.request(baseUrl & path, httpMethod = verb,
    headers = headers, body = "")
  (response.code.int, response.body)

proc sessionTicket(): string =
  let (status, body) = call(HttpPost,
    "/c/ws-http/sessions/" & sessionId & "/ws-ticket", cookie)
  doAssert status == 200, body
  parseJson(body)["ticket"].getStr()

proc sessionWsPath(ticket: string): string =
  "/ws/c/ws-http/sessions/" & sessionId & "?ticket=" & ticket

proc shareTicket(): string =
  let (status, body) = call(HttpPost, "/s/" & shareCode & "/ws-ticket")
  doAssert status == 200, body
  parseJson(body)["ticket"].getStr()

proc setConfigInt(key: string, value: int) =
  ## The cache reloads on the version bump, so the next request sees the change.
  discard database.execUpdate(
    "update platform.config set value = to_jsonb($2::int) where key = $1",
    @[textParam(key), intParam(value.int64)])
  discard database.execUpdate(
    "update platform.config_version set version = version + 1")

proc bootstrap() =
  if dsn().len == 0:
    raise newException(ValueError, "MAJADU_PG_DSN is required")
  database = openDb(dsn(), 8)
  keyring = loadKeyring(keysJson, "1")
  discard database.execUpdate(
    "delete from platform.ws_ticket where user_id in (select id from platform.user where google_sub = 'ws-http-user')")
  discard database.execUpdate(
    """delete from session.sessions where community_id in
         (select id from platform.community
          where slug in ('ws-http','ws-http-other'))""")
  discard database.execUpdate(
    "delete from platform.user where google_sub = 'ws-http-user'")
  discard database.execUpdate(
    """delete from platform.community where slug in ('ws-http','ws-http-other')""")
  userId = database.queryOne(
    """insert into platform.user (google_sub, email_hash, display_name)
       values ('ws-http-user', 'ws-http-hash', 'Member') returning id""").get.get("id")
  communityId = database.queryOne(
    """insert into platform.community (slug, name, timezone)
       values ('ws-http', 'WS HTTP', 'Asia/Jakarta') returning id""").get.get("id")
  let otherCommunityId = database.queryOne(
    """insert into platform.community (slug, name, timezone)
       values ('ws-http-other', 'WS Other', 'Asia/Jakarta') returning id""").get.get("id")
  discard database.execUpdate(
    """insert into community.membership (community_id, user_id, role)
       values ($1::uuid, $2::uuid, 'member')""",
    @[textParam(communityId), textParam(userId)])
  sessionId = database.queryOne(
    """insert into session.sessions (community_id, title, session_date, status, source)
       values ($1::uuid, 'Session', '2026-11-03', 'draft', 'manual') returning id""",
    @[textParam(communityId)]).get.get("id")
  foreignSessionId = database.queryOne(
    """insert into session.sessions (community_id, title, session_date, status, source)
       values ($1::uuid, 'Foreign', '2026-11-03', 'draft', 'manual') returning id""",
    @[textParam(otherCommunityId)]).get.get("id")
  cookie = createSession(database, userId, 30)
  shareCode = shareStore.issue(database, keyring, communityId, sessionId, userId)
  ttl = parseInt(database.queryOne(
    "select value from platform.config where key = 'ws.ticket_ttl_seconds'").get.get("value"))

  install(newApp(database, OidcConfig(), keyring, newConfigCache(database)))
  let server = newServer(handler(), websocketHandler(), workerThreads = 4)
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
  doAssert up, "api did not start on port 18093"

bootstrap()

suite "ws ticket HTTP":
  test "a member gets a session ticket with the configured lifetime":
    let (status, body) = call(HttpPost,
      "/c/ws-http/sessions/" & sessionId & "/ws-ticket", cookie)
    check status == 200
    let payload = parseJson(body)
    check payload["expiresIn"].getInt() == ttl
    check payload["ticket"].getStr().len == 64

  test "a session of another community is 404":
    let (status, _) = call(HttpPost,
      "/c/ws-http/sessions/" & foreignSessionId & "/ws-ticket", cookie)
    check status == 404

  test "no cookie is 401":
    let (status, _) = call(HttpPost,
      "/c/ws-http/sessions/" & sessionId & "/ws-ticket")
    check status == 401

  test "a share ticket needs no cookie":
    let (status, body) = call(HttpPost, "/s/" & shareCode & "/ws-ticket")
    check status == 200
    check parseJson(body)["expiresIn"].getInt() == ttl

  test "an unknown share code is 404":
    let (status, _) = call(HttpPost, "/s/not-a-real-code/ws-ticket")
    check status == 404

  test "a foreign origin is 403 and does not burn the ticket":
    let ticket = sessionTicket()
    let (blocked, _) = call(HttpGet, sessionWsPath(ticket),
      origin = "https://evil.example")
    check blocked == 403
    # The same ticket still works, so the 403 happened before the DELETE.
    let (reached, _) = call(HttpGet, sessionWsPath(ticket), origin = allowedOrigin)
    check reached == 400

  test "the share channel also rejects a foreign origin before resolving":
    let (status, _) = call(HttpGet,
      "/ws/share/" & shareCode & "?ticket=" & repeat('0', 64),
      origin = "https://evil.example")
    check status == 403

  test "a ticket is single use":
    let ticket = sessionTicket()
    let (first, _) = call(HttpGet, sessionWsPath(ticket), origin = allowedOrigin)
    check first == 400 # valid ticket, plain GET is not an upgrade
    let (replay, _) = call(HttpGet, sessionWsPath(ticket), origin = allowedOrigin)
    check replay == 401

  test "an unknown ticket is 401":
    let (status, _) = call(HttpGet,
      "/ws/c/ws-http/sessions/" & sessionId & "?ticket=" & repeat('0', 64),
      origin = allowedOrigin)
    check status == 401

  test "an expired ticket is 401":
    let ticket = sessionTicket()
    discard database.execUpdate(
      """update platform.ws_ticket set expires_at = now() - interval '1 second'
         where token_hash = decode($1,'hex')""",
      @[textParam(sha256Hex(ticket))])
    let (status, _) = call(HttpGet, sessionWsPath(ticket), origin = allowedOrigin)
    check status == 401

  test "a ticket for another session is refused without burning it":
    # The slug is checked before the ticket, so a cross-community id is a 404
    # like every other community route. The caller's own ticket stays usable.
    let ticket = sessionTicket()
    let (status, _) = call(HttpGet,
      "/ws/c/ws-http/sessions/" & foreignSessionId & "?ticket=" & ticket,
      origin = allowedOrigin)
    check status == 404
    let stored = database.queryOne(
      """select count(*) as total from platform.ws_ticket
         where token_hash = decode($1,'hex') and expires_at > now()""",
      @[textParam(sha256Hex(ticket))]).get.get("total")
    check stored == "1"

  test "a live share socket gets ready, pong and closes on a malformed frame":
    let ticket = shareTicket()
    let socket = connectWs("127.0.0.1", 18093,
      "/ws/share/" & shareCode & "?ticket=" & ticket)
    check socket.status == 101
    check socket.receiveText() == readyFrame
    socket.sendText("""{"type":"ping"}""")
    check socket.receiveText() == pongFrame
    socket.sendText("""{"type":"subscribe","lastSeq":0}""")
    socket.sendText("""{"type":"ping"}""")
    check socket.receiveText() == pongFrame
    socket.sendText("not json")
    var closed = false
    try:
      discard socket.receiveText()
    except WsClosed:
      closed = true
    check closed
    closeWs(socket)

  test "the second watcher of a full session gets full":
    setConfigInt("ws.max_watchers_per_session", 1)
    let first = connectWs("127.0.0.1", 18093, sessionWsPath(sessionTicket()))
    check first.status == 101
    check first.receiveText() == readyFrame
    let second = connectWs("127.0.0.1", 18093, sessionWsPath(sessionTicket()))
    check second.receiveText() == fullFrame
    closeWs(first)
    closeWs(second)
    setConfigInt("ws.max_watchers_per_session", 50)

  test "the share scrape ceiling rejects before a ticket is inserted":
    setConfigInt("security.share_scrape_limit", 1)
    let before = database.queryOne(
      """select count(*) as n from platform.ws_ticket t
         join session.links l on l.id = t.channel_id
         where l.code_hash = decode($1,'hex')""",
      @[textParam(sha256Hex(shareCode))]).get.get("n")
    let (status, _) = call(HttpPost, "/s/" & shareCode & "/ws-ticket")
    check status == 429
    let after = database.queryOne(
      """select count(*) as n from platform.ws_ticket t
         join session.links l on l.id = t.channel_id
         where l.code_hash = decode($1,'hex')""",
      @[textParam(sha256Hex(shareCode))]).get.get("n")
    check before == after
    setConfigInt("security.share_scrape_limit", 120)

  test "logout revokes the principal and closes its socket":
    let ticket = sessionTicket()
    let socket = connectWs("127.0.0.1", 18093, sessionWsPath(ticket))
    check socket.receiveText() == readyFrame
    let pending = sessionTicket()
    let (status, _) = call(HttpPost, "/auth/logout", cookie)
    check status == 204
    check socket.receiveText() == revokedFrame
    # A ticket issued before the logout can no longer open a socket.
    let (rejected, _) = call(HttpGet, sessionWsPath(pending), origin = allowedOrigin)
    check rejected == 401
    closeWs(socket)
