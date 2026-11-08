import std/[json, monotimes, net, options, strutils, times, unittest]
import ws_client
import clock
import db/db
import sha256
import share/crypto
import share/store as shareStore
import tests/fixtures
import "../../../../shared/platform-lib/tests/clock_fixture"
import ../../src/live
import ../http_support

const
  port = testPort(18090)
  baseUrl = "http://127.0.0.1:" & $uint16(port)
  wsBase = "ws://127.0.0.1:" & $uint16(port)
  keysJson = """{"1":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="}"""

var
  database: Db
  keyring: Keyring
  userId, hostUserId, communityId, sessionId, foreignSessionId: string
  liveSessionId, liveOtherSessionId: string
  cookie, hostCookie, shareCode, liveShareCode: string
  players: array[4, string]
  ttl: int

proc sessionTicketFor(id, cookie: string): string =
  let response = call(baseUrl, HttpPost,
    "/c/ws-http/sessions/" & id & "/ws-ticket", cookie)
  doAssert response.status == 200, response.body
  parseJson(response.body)["ticket"].getStr()

proc sessionTicket(): string =
  sessionTicketFor(sessionId, cookie)

proc sessionWsPathFor(id, ticket: string): string =
  "/ws/c/ws-http/sessions/" & id & "?ticket=" & ticket

proc sessionWsPath(ticket: string): string =
  sessionWsPathFor(sessionId, ticket)

proc shareTicketFor(code: string): string =
  let response = call(baseUrl, HttpPost, "/s/" & code & "/ws-ticket")
  doAssert response.status == 200, response.body
  parseJson(response.body)["ticket"].getStr()

proc shareTicket(): string =
  shareTicketFor(shareCode)

proc shareWsPath(code, ticket: string): string =
  "/ws/share/" & code & "?ticket=" & ticket

proc setConfigInt(key: string, value: int) =
  ## The cache reloads on the version bump, so the next request sees the change.
  discard database.execUpdate(
    "update platform.config set value = to_jsonb($2::int) where key = $1",
    @[textParam(key), intParam(value.int64)])
  discard database.execUpdate(
    "update platform.config_version set version = version + 1")

proc writeSchedule(id, cookie, version: string, sideA, sideB: seq[string]): HttpResult =
  let body = %*{"games": [{"round": 0, "court": 0,
    "sideA": sideA, "sideB": sideB}]}
  call(baseUrl, HttpPut, "/c/ws-http/sessions/" & id & "/schedule", cookie,
    $body, ifMatch = "\"" & version & "\"")

proc bootstrap() =
  requireDatabase()
  database = openDb(dsn(), 8)
  keyring = loadKeyring(keysJson, "1")
  for slug in ["ws-http", "ws-http-other"]:
    purgeCommunity(database, slug)
  discard database.execUpdate(
    """delete from platform.ws_ticket where user_id in
         (select id from platform.user where google_sub like 'ws-http-%')""")
  cleanupUsers(database, "ws-http-%")
  userId = newUser(database, "ws-http-user", "ws-http-hash", "Member")
  hostUserId = newUser(database, "ws-http-host", "ws-http-host-hash", "Host")
  communityId = newCommunity(database, "ws-http", "WS HTTP")
  let otherCommunityId = newCommunity(database, "ws-http-other", "WS Other")
  newMember(database, communityId, userId, "member")
  newMember(database, communityId, hostUserId, "host")
  for index, name in ["Watcher One", "Watcher Two", "Watcher Three", "Watcher Four"]:
    players[index] = newPlayer(database, communityId, name)
  sessionId = newSession(database, communityId, "Session", "2026-11-03")
  foreignSessionId = newSession(database, otherCommunityId, "Foreign",
    "2026-11-03")
  # Live fan-out gets sessions of its own so a write here cannot change the
  # version the transport cases above assert.
  liveSessionId = newSession(database, communityId, "Fanout", "2026-11-04")
  liveOtherSessionId = newSession(database, communityId, "Other fanout",
    "2026-11-04")
  cookie = cookieFor(database, userId)
  hostCookie = cookieFor(database, hostUserId)
  shareCode = shareStore.issue(database, keyring, communityId, sessionId, userId, 30)
  liveShareCode = shareStore.issue(database, keyring, communityId, liveSessionId,
    userId, 30)
  ttl = parseInt(database.queryOne(
    "select value from platform.config where key = 'ws.ticket_ttl_seconds'").get.get("value"))

  startServer(newTestApp(database), port, baseUrl, websocket = true)

bootstrap()

suite "ws ticket HTTP":
  test "a member gets a session ticket with the configured lifetime":
    let status = call(baseUrl, HttpPost,
      "/c/ws-http/sessions/" & sessionId & "/ws-ticket", cookie)
    let body = status.body
    expectStatus(status, 200)
    let payload = parseJson(body)
    check payload["expiresIn"].getInt() == ttl
    check payload["ticket"].getStr().len == 64

  test "a session of another community is 404":
    let status = call(baseUrl, HttpPost,
      "/c/ws-http/sessions/" & foreignSessionId & "/ws-ticket", cookie)
    expectProblem(status, 404)

  test "no cookie is 401":
    let status = call(baseUrl, HttpPost,
      "/c/ws-http/sessions/" & sessionId & "/ws-ticket")
    expectProblem(status, 401)

  test "a share ticket needs no cookie":
    let status = call(baseUrl, HttpPost, "/s/" & shareCode & "/ws-ticket")
    let body = status.body
    expectStatus(status, 200)
    check parseJson(body)["expiresIn"].getInt() == ttl

  test "an unknown share code is 404":
    let status = call(baseUrl, HttpPost, "/s/not-a-real-code/ws-ticket")
    expectProblem(status, 404)

  test "a foreign origin is 403 and does not burn the ticket":
    let ticket = sessionTicket()
    let blocked = call(baseUrl, HttpGet, sessionWsPath(ticket),
      origin = "https://evil.example")
    expectProblem(blocked, 403)
    # The same ticket still works, so the 403 happened before the DELETE.
    let reached = call(baseUrl, HttpGet, sessionWsPath(ticket), origin = allowedOrigin)
    expectProblem(reached, 400)

  test "the share channel also rejects a foreign origin before resolving":
    let status = call(baseUrl, HttpGet,
      "/ws/share/" & shareCode & "?ticket=" & repeat('0', 64),
      origin = "https://evil.example")
    expectProblem(status, 403)

  test "a ticket is single use":
    let ticket = sessionTicket()
    let first = call(baseUrl, HttpGet, sessionWsPath(ticket), origin = allowedOrigin)
    expectProblem(first, 400) # valid ticket, plain GET is not an upgrade
    let replay = call(baseUrl, HttpGet, sessionWsPath(ticket), origin = allowedOrigin)
    expectProblem(replay, 401)

  test "an unknown ticket is 401":
    let status = call(baseUrl, HttpGet,
      "/ws/c/ws-http/sessions/" & sessionId & "?ticket=" & repeat('0', 64),
      origin = allowedOrigin)
    expectProblem(status, 401)

  test "an expired ticket is 401":
    # The expiry value comes from the pinned clock, so the case does not do
    # wall-clock arithmetic in SQL. The database's `now()` is later than the
    # pinned instant, which is what makes the ticket exactly expired.
    withPinnedClock("2020-01-01T00:00:00Z"):
      let ticket = sessionTicket()
      discard database.execUpdate(
        """update platform.ws_ticket set expires_at = $2::timestamptz
           where token_hash = decode($1,'hex')""",
        @[textParam(sha256Hex(ticket)),
          textParam(utcNow().format("yyyy-MM-dd'T'HH:mm:ss'Z'"))])
      let status = call(baseUrl, HttpGet, sessionWsPath(ticket), origin = allowedOrigin)
      expectProblem(status, 401)

  test "a ticket for another session is refused without burning it":
    # The slug is checked before the ticket, so a cross-community id is a 404
    # like every other community route. The caller's own ticket stays usable.
    let ticket = sessionTicket()
    let status = call(baseUrl, HttpGet,
      "/ws/c/ws-http/sessions/" & foreignSessionId & "?ticket=" & ticket,
      origin = allowedOrigin)
    expectProblem(status, 404)
    let stored = database.queryOne(
      """select count(*) as total from platform.ws_ticket
         where token_hash = decode($1,'hex') and expires_at > now()""",
      @[textParam(sha256Hex(ticket))]).get.get("total")
    check stored == "1"

  test "a live share socket gets ready, pong and closes on a malformed frame":
    let ticket = shareTicket()
    let socket = connectWs("127.0.0.1", int(port),
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

  test "the helper opens, subscribes, and reconnects at the last sequence":
    let first = openWs("127.0.0.1", int(port), sessionWsPath(sessionTicket()))
    first.subscribe(0)
    first.sendText("""{"type":"ping"}""")
    check first.receiveText() == pongFrame
    # The old socket is closed by the helper; the new ticket is a fresh one
    # because the first was consumed by the first upgrade.
    let resumed = first.reconnect("127.0.0.1", int(port),
      sessionWsPath(sessionTicket()), 7)
    check resumed.sent == @["""{"type":"subscribe","lastSeq":7}"""]
    resumed.sendText("""{"type":"ping"}""")
    check resumed.receiveText() == pongFrame
    closeWs(resumed)

  test "the second watcher of a full session gets full":
    setConfigInt("ws.max_watchers_per_session", 1)
    let first = connectWs("127.0.0.1", int(port), sessionWsPath(sessionTicket()))
    check first.status == 101
    check first.receiveText() == readyFrame
    let second = connectWs("127.0.0.1", int(port), sessionWsPath(sessionTicket()))
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
    let limited = call(baseUrl, HttpPost, "/s/" & shareCode & "/ws-ticket")
    # The 429 goes through `problem()` like every other rejection, with
    # `retryAfter` as an extra field rather than a second envelope.
    expectProblem(limited, 429, "RATE_LIMITED")
    check parseJson(limited.body)["retryAfter"].kind == JInt
    let after = database.queryOne(
      """select count(*) as n from platform.ws_ticket t
         join session.links l on l.id = t.channel_id
         where l.code_hash = decode($1,'hex')""",
      @[textParam(sha256Hex(shareCode))]).get.get("n")
    check before == after
    setConfigInt("security.share_scrape_limit", 120)

  test "two session watchers receive session.changed after each write":
    let first = openWs("127.0.0.1", int(port),
      sessionWsPathFor(liveSessionId, sessionTicketFor(liveSessionId, cookie)))
    let second = openWs("127.0.0.1", int(port),
      sessionWsPathFor(liveSessionId, sessionTicketFor(liveSessionId, cookie)))
    let schedule = writeSchedule(liveSessionId, hostCookie, "1",
      @[players[0], players[1]], @[players[2], players[3]])
    expectStatus(schedule, 200)
    let afterSchedule = """{"type":"session.changed","seq":2}"""
    check first.receiveText() == afterSchedule
    check second.receiveText() == afterSchedule
    let game = call(baseUrl, HttpPatch,
      "/c/ws-http/sessions/" & liveSessionId & "/games/0-0", hostCookie,
      """{"scoreA":21,"scoreB":15}""", ifMatch = "\"2\"")
    expectStatus(game, 200)
    let afterGame = """{"type":"session.changed","seq":3}"""
    check first.receiveText() == afterGame
    check second.receiveText() == afterGame
    let patched = call(baseUrl, HttpPatch,
      "/c/ws-http/sessions/" & liveSessionId, hostCookie,
      """{"title":"Renamed"}""", ifMatch = "\"3\"")
    expectStatus(patched, 200)
    let afterSession = """{"type":"session.changed","seq":4}"""
    check first.receiveText() == afterSession
    check second.receiveText() == afterSession
    closeWs(first)
    closeWs(second)

  test "session.changed stays inside its own session channel":
    let watcher = openWs("127.0.0.1", int(port),
      sessionWsPathFor(liveSessionId, sessionTicketFor(liveSessionId, cookie)))
    let elsewhere = openWs("127.0.0.1", int(port),
      sessionWsPathFor(liveOtherSessionId,
        sessionTicketFor(liveOtherSessionId, cookie)))
    let patched = call(baseUrl, HttpPatch,
      "/c/ws-http/sessions/" & liveSessionId, hostCookie,
      """{"title":"Only here"}""", ifMatch = "\"4\"")
    expectStatus(patched, 200)
    check watcher.receiveText() == """{"type":"session.changed","seq":5}"""
    var timedOut = false
    try:
      discard elsewhere.receiveText(300)
    except TimeoutError:
      timedOut = true
    check timedOut
    closeWs(watcher)
    closeWs(elsewhere)

  test "deleting a share link sends revoked, closes, and burns its tickets":
    let watcher = openWs("127.0.0.1", int(port),
      shareWsPath(shareCode, shareTicket()))
    # Issued before the delete and never used: revocation must remove it too.
    let pending = shareTicket()
    let deleted = call(baseUrl, HttpDelete,
      "/c/ws-http/sessions/" & sessionId & "/share", hostCookie)
    expectStatus(deleted, 204)
    check watcher.receiveText() == revokedFrame
    var closed = false
    try:
      discard watcher.receiveText()
    except WsClosed:
      closed = true
    check closed
    let rejected = call(baseUrl, HttpGet, shareWsPath(shareCode, pending),
      origin = allowedOrigin)
    expectProblem(rejected, 401)
    # A newly requested ticket cannot exist either: the code no longer resolves,
    # so the issue route answers 404 before minting anything (app.nim:981-984).
    let reissue = call(baseUrl, HttpPost, "/s/" & shareCode & "/ws-ticket")
    expectProblem(reissue, 404)
    closeWs(watcher)

  test "a closed watcher frees its per-session slot":
    setConfigInt("ws.max_watchers_per_session", 2)
    let first = openWs("127.0.0.1", int(port),
      sessionWsPathFor(liveSessionId, sessionTicketFor(liveSessionId, cookie)))
    let second = openWs("127.0.0.1", int(port),
      sessionWsPathFor(liveSessionId, sessionTicketFor(liveSessionId, cookie)))
    closeWs(first)
    # The release runs on the server's CloseEvent, so this is a bounded poll:
    # each attempt reads its first frame with a socket timeout, never a sleep.
    let deadline = getMonoTime() + initDuration(seconds = 3)
    var admitted: WsClient
    while getMonoTime() < deadline:
      let candidate = connectWs("127.0.0.1", int(port),
        sessionWsPathFor(liveSessionId,
          sessionTicketFor(liveSessionId, cookie)))
      var admittedNow = false
      if candidate.status == 101:
        try:
          admittedNow = candidate.receiveText(250) == readyFrame
        except TimeoutError:
          admittedNow = false
      if admittedNow:
        admitted = candidate
        break
      closeWs(candidate)
    check admitted != nil
    closeWs(second)
    closeWs(admitted)
    setConfigInt("ws.max_watchers_per_session", 50)

  test "logout revokes the principal and closes its socket":
    let ticket = sessionTicket()
    let socket = connectWs("127.0.0.1", int(port), sessionWsPath(ticket))
    check socket.receiveText() == readyFrame
    let pending = sessionTicket()
    let status = call(baseUrl, HttpPost, "/auth/logout", cookie)
    expectStatus(status, 204)
    check socket.receiveText() == revokedFrame
    # A ticket issued before the logout can no longer open a socket.
    let rejected = call(baseUrl, HttpGet, sessionWsPath(pending), origin = allowedOrigin)
    expectProblem(rejected, 401)
    closeWs(socket)
