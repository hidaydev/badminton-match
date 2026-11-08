## The size guard on a real socket: `rejectLargeBody` and `bodyTooLarge` run
## before every other guard, so an oversized request must be answered with a
## problem document and must not reach a handler that writes.
##
## The limit is read from the configured snapshot, never repeated here: the
## shared `security.max_body_bytes` row is 1 MiB in the seed, and a test that
## hardcoded it would pass a rule the deployment no longer has.

import std/[json, options, os, strutils, unittest]
import mummy
import db/db
import community/infrastructure/community_store
import platform/config/store
import tests/fixtures
import ../../src/app
import ../http_support

const
  port = testPort(18104)
  baseUrl = "http://127.0.0.1:" & $uint16(port)
  slug = "body-limit-club"
  hostEmail = "limit-host@example.com"

type
  ServeArgs = object
    server: Server
    port: Port

proc serveThread(args: ServeArgs) {.thread.} =
  try:
    args.server.serve(args.port, "127.0.0.1")
  except MummyError:
    discard

proc startServerWithHeadroom(app: App, port: Port, baseUrl: string,
                             transportCap: int) =
  ## mummy refuses a body past its own `maxBodyLen` by closing the socket before
  ## any handler runs. Its default is exactly the seeded limit, so a 413 case
  ## would be answered by the transport and the guard would stay untested. The
  ## transport cap is lifted past the configured limit; the guard is what
  ## decides.
  install(app)
  let server = newServer(handler(), workerThreads = 4,
    maxBodyLen = transportCap)
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
  doAssert up, "api did not start on port " & $uint16(port)

proc paddedSessionBody(size: int, title: string): string =
  ## Exactly `size` bytes of valid JSON. The create handler ignores unknown
  ## keys, so `pad` only carries length.
  let head = "{\"title\":\"" & title & "\",\"date\":\"2026-11-09\",\"pad\":\""
  let tail = "\"}"
  if size < head.len + tail.len:
    raise newException(ValueError, "size is too small for a session body")
  head & repeat('x', size - head.len - tail.len) & tail

var
  database: Db
  communityId: string
  hostCookie: string
  limit: int

proc sessionCount(title: string): int =
  database.queryOne(
    """select count(*) as total from session.sessions
        where community_id = $1::uuid and title = $2""",
    @[textParam(communityId), textParam(title)]).get.getInt("total")

proc bootstrap() =
  database = openDb(dsn(), 1)
  purgeCommunity(database, slug)
  discard database.execUpdate(
    """delete from platform.idempotency_keys where user_id in
         (select id from platform.user where google_sub like 'limit-%')""")
  discard database.execUpdate(
    "delete from platform.user where google_sub like 'limit-%'")
  let ownerId = newUser(database, "limit-owner", "limit-owner@example.com",
    "Owner", owner = true)
  communityId = community_store.create(database, slug, "Body Limit Club",
    hostEmail, "Asia/Jakarta", ownerId).communityId
  let hostId = newUser(database, "limit-host", hostEmail, "Host")
  newMember(database, communityId, hostId, "host")
  hostCookie = cookieFor(database, hostId)
  limit = loadSnapshot(database).intValue(%*{}, keySecurityMaxBodyBytes)
  doAssert limit > 0, "security.max_body_bytes must be a positive limit"
  startServerWithHeadroom(newTestApp(database), port, baseUrl, limit + 4096)

bootstrap()

suite "body size guard over HTTP":
  test "a body one byte over the limit is a 413 and writes no session":
    let body = paddedSessionBody(limit + 1, "TooBig")
    check body.len == limit + 1
    let response = call(baseUrl, HttpPost, "/c/" & slug & "/sessions",
      hostCookie, body)
    let responseBody = response.body
    check response.status == 413
    check header(response, "Content-Type").startsWith("application/problem+json")
    let parsed = parseJson(responseBody)
    check parsed["code"].getStr() == "BODY_TOO_LARGE"
    check parsed["detail"].getStr().len > 0
    check sessionCount("TooBig") == 0

  test "a body one byte under the limit is accepted":
    let body = paddedSessionBody(limit - 1, "JustUnder")
    check body.len == limit - 1
    let response = call(baseUrl, HttpPost, "/c/" & slug & "/sessions",
      hostCookie, body)
    let responseBody = response.body
    check response.status == 201
    check parseJson(responseBody)["title"].getStr() == "JustUnder"
    check sessionCount("JustUnder") == 1

  test "a request without a body never reaches the size guard":
    # `rejectLargeBody` returns early on an empty body, which is what keeps a
    # probe from being measured against a limit it has no body for.
    let response = call(baseUrl, HttpGet, "/healthz")
    check response.status == 200

  test "the guard reads the body, not the method":
    let body = paddedSessionBody(limit + 1, "GetTooBig")
    let response = call(baseUrl, HttpGet, "/healthz", hostCookie, body)
    check response.status == 413
    check parseJson(response.body)["code"].getStr() == "BODY_TOO_LARGE"