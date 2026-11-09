import std/[json, options, unittest]
import ws_client
import db/db
import tests/fixtures
import ../http_support
import ../../src/live

let
  port = testPort()
  baseUrl = "http://127.0.0.1:" & $uint16(port)
  userSub = "be04-user"

var
  database: Db
  userId, sessionId: string
  callCookie, otherCookie: string

proc liveSessions(): int =
  ## Only the caller's unrevoked rows, so a leftover session from another suite
  ## can never make a row-count assertion pass or fail for the wrong reason.
  database.queryOne(
    """select count(*) as n from account.sessions
       where user_id = $1::uuid and revoked_at is null""",
    @[textParam(userId)]).get.getInt("n")

proc ticketRows(): int =
  database.queryOne(
    """select count(*) as n from platform.ws_ticket
       where user_id = $1::uuid""",
    @[textParam(userId)]).get.getInt("n")

proc revokeAudits(): int =
  database.queryOne(
    """select count(*) as n from account.audit
       where action = 'auth.sessions.revoke_others'
         and actor_id = $1::uuid and target_id = $1::text""",
    @[textParam(userId)]).get.getInt("n")

proc sessionTicket(cookie: string): string =
  let response = call(baseUrl, HttpPost,
    "/c/be04-club/sessions/" & sessionId & "/ws-ticket", cookie)
  doAssert response.status == 200, response.body
  parseJson(response.body)["ticket"].getStr()

proc bootstrap() =
  requireDatabase()
  database = openDb(dsn(), 4)
  purgeCommunity(database, "be04-club")
  cleanupUsers(database, "be04-%")
  let ownerId = newUser(database, "be04-owner", "be04-owner@example.com",
    "BE04 Owner", owner = true)
  userId = newUser(database, userSub, "be04-user@example.com", "BE04 User")
  let communityId = newCommunity(database, "be04-club", "BE04 Club")
  newMember(database, communityId, ownerId, "admin")
  newMember(database, communityId, userId, "host")
  sessionId = newSession(database, communityId, "BE04 night", "2026-11-10")
  # Two logins of the same person: the fixture the list and the revoke both
  # need, written once.
  callCookie = cookieFor(database, userId)
  otherCookie = cookieFor(database, userId)
  startServer(newTestApp(database), port, baseUrl, websocket = true)

bootstrap()

suite "auth sessions HTTP":
  test "two logins list two rows and each caller sees its own as current":
    let status = call(baseUrl, HttpGet, "/auth/sessions", callCookie)
    let body = status.body
    expectStatus(status, 200)
    let items = parseJson(body)["items"]
    check liveSessions() == 2
    check items.len == 2
    var listed: seq[string] = @[]
    var current: seq[string] = @[]
    for item in items:
      listed.add(item["id"].getStr())
      # Both timestamps come back as ISO strings the client formats.
      check item["createdAt"].getStr().len >= 19
      check item["lastSeenAt"].getStr().len >= 19
      if item["current"].getBool():
        current.add(item["id"].getStr())
    check current.len == 1
    for row in database.query(
      """select id from account.sessions
         where user_id = $1::uuid and revoked_at is null""",
      @[textParam(userId)]):
      check row.getUuid("id") in listed
    # The other login lists the same two rows and marks the other one current.
    let secondStatus = call(baseUrl, HttpGet, "/auth/sessions", otherCookie)
    let secondBody = secondStatus.body
    expectStatus(secondStatus, 200)
    let secondItems = parseJson(secondBody)["items"]
    check secondItems.len == 2
    var secondCurrent: seq[string] = @[]
    for item in secondItems:
      if item["current"].getBool():
        secondCurrent.add(item["id"].getStr())
    check secondCurrent.len == 1
    check secondCurrent[0] != current[0]

  test "no session cookie is 401":
    let status = call(baseUrl, HttpGet, "/auth/sessions")
    expectProblem(status, 401, "UNAUTHENTICATED")

  test "revoking others deletes the principal's tickets and closes its socket":
    let watched = sessionTicket(callCookie)
    let socket = connectWs("127.0.0.1", int(port),
      "/ws/c/be04-club/sessions/" & sessionId & "?ticket=" & watched)
    check socket.status == 101
    check socket.receiveText() == readyFrame
    # A ticket issued but not yet used must not survive the revoke either.
    let unused = sessionTicket(callCookie)
    check unused.len == 64
    check ticketRows() == 1
    let status = call(baseUrl, HttpDelete, "/auth/sessions", callCookie)
    expectStatus(status, 204)
    check socket.receiveText() == revokedFrame
    var closed = false
    try:
      discard socket.receiveText()
    except WsClosed:
      closed = true
    check closed
    check ticketRows() == 0
    closeWs(socket)

  test "revoking others keeps the caller's session and audits it once":
    # A fresh second login stands in for the one the previous case revoked.
    otherCookie = cookieFor(database, userId)
    check liveSessions() == 2
    let before = revokeAudits()
    let status = call(baseUrl, HttpDelete, "/auth/sessions", callCookie)
    expectStatus(status, 204)
    check liveSessions() == 1
    let mine = call(baseUrl, HttpGet, "/auth/me", callCookie)
    let mineBody = mine.body
    expectStatus(mine, 200)
    check parseJson(mineBody)["id"].getStr() == userId
    let theirs = call(baseUrl, HttpGet, "/auth/me", otherCookie)
    expectProblem(theirs, 401)
    check revokeAudits() == before + 1

  test "a second revoke answers 204 and leaves the caller signed in":
    let status = call(baseUrl, HttpDelete, "/auth/sessions", callCookie)
    expectStatus(status, 204)
    check liveSessions() == 1
    let list = call(baseUrl, HttpGet, "/auth/sessions", callCookie)
    let body = list.body
    expectStatus(list, 200)
    let items = parseJson(body)["items"]
    check items.len == 1
    check items[0]["current"].getBool()
    purgeCommunity(database, "be04-club")
    cleanupUsers(database, "be04-%")