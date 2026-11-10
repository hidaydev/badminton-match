## The size guard on a real socket: `rejectLargeBody` and `bodyTooLarge` run
## before every other guard, so an oversized request must be answered with a
## problem document and must not reach a handler that writes.
##
## The limit is read from the configured snapshot, never repeated here: the
## shared `security.max_body_bytes` row is 1 MiB in the seed, and a test that
## hardcoded it would pass a rule the deployment no longer has.
##
## BE-16: the seed hid the defect, because the socket default and the configured
## value agreed at 1 MiB. This suite raises the row to 2 MiB, so a 1.5 MiB body
## can only arrive if the socket follows the config's declared ceiling rather
## than its own default, and a 3 MiB body is answered by the guard with a 413
## envelope instead of a dropped connection.

import std/[json, options, strutils, unittest]
import mummy
import db/db
import waiters
import community/infrastructure/community_store
import platform/config/store
import tests/fixtures
import ../../src/app
import ../../src/main
import ../../src/security_headers
import ../http_support

let
  port = testPort()
  baseUrl = "http://127.0.0.1:" & $uint16(port)
  slug = "body-limit-club"
  hostEmail = "limit-host@example.com"
  ## The DoD value from BE-16: high enough that the transport default would
  ## have dropped the body, low enough that the guard still decides.
  raisedLimit = 2_097_152
  underLimitBody = 1_572_864
  overLimitBody = 3 * 1024 * 1024

type
  ServeArgs = object
    server: Server
    port: Port

proc serveThread(args: ServeArgs) {.thread.} =
  try:
    args.server.serve(args.port, "127.0.0.1")
  except MummyError:
    discard

proc startServer(app: App, port: Port, baseUrl: string, socketBytes: int) =
  ## `socketBytes` is the boot value: `bodyLimits` over the same snapshot, the
  ## registry ceiling for the body key, so the guard, not the transport, answers
  ## an oversized request. A cap left at mummy's 1 MiB default would close the
  ## socket first and the 413 path would stay untested.
  install(app)
  let booted = BootedApi(handler: handler(), socketBytes: socketBytes)
  let server = newApiServer(booted, 4)
  var thread: Thread[ServeArgs]
  createThread(thread, serveThread, ServeArgs(server: server, port: port))
  # SQ-26: a bounded poll, not a fixed number of sleeps.
  waitForHttp(baseUrl & "/healthz")

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
  seededLimit: int

proc sessionCount(title: string): int =
  database.queryOne(
    """select count(*) as total from session.sessions
        where community_id = $1::uuid and title = $2""",
    @[textParam(communityId), textParam(title)]).get.getInt("total")

proc setMaxBodyBytes(value: int) =
  ## The cache reloads on the version counter, so the write must bump it too;
  ## updating the row alone would leave every worker on the old snapshot.
  discard database.execUpdate(
    "update platform.config set value = $1 where key = $2",
    @[textParam($value), textParam($keySecurityMaxBodyBytes)])
  discard database.execUpdate(
    "update platform.config_version set version = version + 1")

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
  seededLimit = loadSnapshot(database).intValue(%*{}, keySecurityMaxBodyBytes)
  doAssert seededLimit > 0, "security.max_body_bytes must be a positive limit"
  setMaxBodyBytes(raisedLimit)
  let limits = bodyLimits(loadSnapshot(database))
  limit = limits.guardBytes
  doAssert limit == raisedLimit, "the guard must follow the configured value"
  doAssert limits.socketBytes >= overLimitBody,
    "the socket must accept every body the guard has to answer for"
  startServer(newTestApp(database), port, baseUrl, limits.socketBytes)

bootstrap()

suite "body size guard over HTTP":
  test "a 1.5 MB body reaches the handler under a 2 MiB limit":
    # The old socket default was 1 MiB, so this body was dropped mid-request
    # and the client never saw an answer. It is a legal body now.
    let body = paddedSessionBody(underLimitBody, "OneAndAHalf")
    check body.len == underLimitBody
    let response = call(baseUrl, HttpPost, "/c/" & slug & "/sessions",
      hostCookie, body)
    check response.status == 201
    check parseJson(response.body)["title"].getStr() == "OneAndAHalf"
    check sessionCount("OneAndAHalf") == 1

  test "a 3 MB body is answered with the 413 envelope, not a closed socket":
    let body = paddedSessionBody(overLimitBody, "WayTooBig")
    check body.len == overLimitBody
    let response = call(baseUrl, HttpPost, "/c/" & slug & "/sessions",
      hostCookie, body)
    check response.status == 413
    check header(response, "Content-Type").startsWith("application/problem+json")
    let parsed = parseJson(response.body)
    check parsed["code"].getStr() == "BODY_TOO_LARGE"
    check parsed["detail"].getStr().len > 0
    # QAE-06: the guard runs inside `route()`, after `beginRequest()`, so the
    # rejection is a logged request with an id rather than a line-less drop.
    check parsed["request_id"].getStr().len == 36
    check sessionCount("WayTooBig") == 0

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
    let response = call(baseUrl, HttpGet, "/version", hostCookie, body)
    check response.status == 413
    check parseJson(response.body)["code"].getStr() == "BODY_TOO_LARGE"

# The row belongs to the deployment, not to this suite: a standalone run with
# isolation off must leave the seeded limit behind for the next file.
setMaxBodyBytes(seededLimit)
