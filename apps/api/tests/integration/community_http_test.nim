import std/[httpclient, json, options, os, sequtils, strutils, unittest]
import mummy
import db/db
import sha256
import ../../src/app
import ../../src/live
import account/infrastructure/oidc
import account/infrastructure/session_store
import community/domain/community
import community/infrastructure/[community_store, invite, membership]
import platform/config/store
import share/crypto

const
  baseUrl = "http://127.0.0.1:18094"
  port = Port(18094)
  keysJson = """{"1":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="}"""
  ownerEmail = "http-owner@example.com"
  adminEmail = "http-admin@example.com"
  memberEmail = "http-member@example.com"
  expectedVersion = staticRead("../../../../VERSION").strip()

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
  ownerId, adminId, memberId: string
  ownerCookie, adminCookie, memberCookie: string
  clubId, closedId: string

proc dsn(): string = getEnv("MAJADU_PG_DSN")

proc call(verb: HttpMethod, path: string, cookie = "",
          body = ""): (int, string) =
  let client = newHttpClient(timeout = 5000)
  defer: client.close()
  var headers = newHttpHeaders()
  headers["Origin"] = "http://127.0.0.1:5173"
  if cookie.len > 0:
    headers["Cookie"] = "majadu_session=" & cookie
  if body.len > 0:
    headers["Content-Type"] = "application/json"
  let response = client.request(baseUrl & path, httpMethod = verb,
    headers = headers, body = body)
  (response.code.int, response.body)

proc user(googleSub, email: string, owner = false): string =
  database.queryOne(
    """insert into platform.user (google_sub, email_hash, display_name, is_platform_owner)
       values ($1, $2, $1, $3) returning id""",
    @[textParam(googleSub), textParam(sha256Hex(email)), boolParam(owner)]
    ).get.get("id")

proc bootstrap() =
  database = openDb(dsn(), 1)
  discard database.execUpdate(
    "delete from platform.community where slug in ('http-club', 'http-closed')")
  discard database.execUpdate("delete from platform.user where google_sub like 'http-%'")
  ownerId = user("http-owner", ownerEmail, owner = true)
  adminId = user("http-admin", adminEmail)
  memberId = user("http-member", memberEmail)
  clubId = community_store.create(database, "http-club", "HTTP Club", adminEmail,
    "Asia/Jakarta", ownerId).communityId
  closedId = community_store.create(database, "http-closed", "HTTP Closed",
    adminEmail, "Asia/Jakarta", ownerId).communityId
  discard database.execUpdate(
    """insert into community.membership (community_id, user_id, role)
       values ($1::uuid, $2::uuid, 'admin'), ($3::uuid, $2::uuid, 'admin')""",
    @[textParam(clubId), textParam(adminId), textParam(closedId)])
  ownerCookie = createSession(database, ownerId, 30)
  adminCookie = createSession(database, adminId, 30)
  memberCookie = createSession(database, memberId, 30)

  install(newApp(database, OidcConfig(), loadKeyring(keysJson, "1"),
    newConfigCache(database)))
  let server = newServer(handler(), workerThreads = 4)
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
  doAssert up, "api did not start on port 18094"

bootstrap()

suite "community HTTP":
  test "only the platform owner creates a community, and it needs an admin email":
    let (anonymous, _) = call(HttpPost, "/communities",
      body = """{"slug":"http-new","name":"New","adminEmail":"x@example.com"}""")
    check anonymous == 401
    let (notOwner, _) = call(HttpPost, "/communities", adminCookie,
      """{"slug":"http-new","name":"New","adminEmail":"x@example.com"}""")
    check notOwner == 403
    let (noEmail, _) = call(HttpPost, "/communities", ownerCookie,
      """{"slug":"http-new","name":"New"}""")
    check noEmail == 400
    let (badSlug, _) = call(HttpPost, "/communities", ownerCookie,
      """{"slug":"a/b","name":"New","adminEmail":"x@example.com"}""")
    check badSlug == 400
    let (created, body) = call(HttpPost, "/communities", ownerCookie,
      """{"slug":"http-new","name":"New","adminEmail":"new@example.com"}""")
    check created == 201
    check parseJson(body)["timezone"].getStr() == "Asia/Jakarta"
    let (duplicate, _) = call(HttpPost, "/communities", ownerCookie,
      """{"slug":"http-new","name":"Again","adminEmail":"new@example.com"}""")
    check duplicate == 409

  test "the directory shows only opted-in communities to outsiders":
    discard database.execUpdate(
      "delete from platform.community where slug = 'http-new'")
    let (anonymousStatus, anonymousBody) = call(HttpGet, "/directory")
    check anonymousStatus == 200
    check "http-club" notin anonymousBody
    discard database.execUpdate(
      """insert into community.settings (community_id, values)
         values ($1::uuid, '{"community.directory_enabled": true}')
         on conflict (community_id) do update set values = excluded.values""",
      @[textParam(clubId)])
    let (status, body) = call(HttpGet, "/directory")
    check status == 200
    let items = parseJson(body)["items"]
    var entry: JsonNode
    for item in items:
      if item["slug"].getStr() == "http-club":
        entry = item
    check entry.len == 2
    check entry["name"].getStr() == "HTTP Club"

  test "an invitation is bound to the address and single use":
    let (inviteStatus, inviteBody) = call(HttpPost, "/c/http-club/invites",
      adminCookie, "{\"email\":\"" & memberEmail & "\",\"role\":\"host\"}")
    check inviteStatus == 201
    let token = parseJson(inviteBody)["token"].getStr()
    let (wrong, _) = call(HttpPost, "/invites/" & token & "/accept", adminCookie)
    check wrong == 403
    let (accepted, acceptedBody) = call(HttpPost, "/invites/" & token & "/accept",
      memberCookie)
    check accepted == 201
    check parseJson(acceptedBody)["role"].getStr() == "host"
    # Login auto-accepts the invite for its address, so a later click reports
    # the same membership instead of a misleading "already used".
    let (reused, reusedBody) = call(HttpPost, "/invites/" & token & "/accept",
      memberCookie)
    check reused == 201
    check parseJson(reusedBody)["role"].getStr() == "host"
    # Another account cannot reuse the token.
    let (stolen, _) = call(HttpPost, "/invites/" & token & "/accept", adminCookie)
    check stolen == 403
    check membership.list(database, clubId).anyIt(it.userId == memberId)

  test "join requests answer identically and are decided once":
    let (missing, missingBody) = call(HttpPost, "/c/nope/join-requests",
      memberCookie)
    let (disabled, disabledBody) = call(HttpPost, "/c/http-closed/join-requests",
      memberCookie)
    check missing == 202
    check missingBody == disabledBody
    discard database.execUpdate(
      """insert into community.settings (community_id, values)
         values ($1::uuid, '{"community.join_requests_enabled": true}')
         on conflict (community_id) do update set values = excluded.values""",
      @[textParam(closedId)])
    let (pending, pendingBody) = call(HttpPost, "/c/http-closed/join-requests",
      memberCookie)
    let (again, againBody) = call(HttpPost, "/c/http-closed/join-requests",
      memberCookie)
    check pending == 202
    check againBody == pendingBody
    let requestAudit = database.queryOne(
      """select after from account.audit
         where action = 'community.join.requested' and target_id = $1
           and community_id = $2::uuid
         order by occurred_at desc limit 1""",
      @[textParam(memberId), textParam(closedId)])
    check requestAudit.isSome
    let (listStatus, listBody) = call(HttpGet, "/c/http-closed/join-requests",
      adminCookie)
    check listStatus == 200
    let items = parseJson(listBody)["items"]
    check items.len == 1
    let requestId = items[0]["id"].getStr()
    let (decided, _) = call(HttpPatch, "/c/http-closed/join-requests/" & requestId,
      adminCookie, """{"decision":"approve"}""")
    check decided == 200
    let (twice, _) = call(HttpPatch, "/c/http-closed/join-requests/" & requestId,
      adminCookie, """{"decision":"approve"}""")
    check twice == 404
    check membership.list(database, closedId).anyIt(it.userId == memberId)

  test "role changes are admin-only and never remove the last admin":
    let (forbidden, _) = call(HttpGet, "/c/http-club/members", memberCookie)
    check forbidden == 200
    let (patchAsMember, _) = call(HttpPatch,
      "/c/http-club/members/" & memberId, memberCookie, """{"role":"admin"}""")
    check patchAsMember == 403
    let (demoteLast, _) = call(HttpPatch, "/c/http-club/members/" & adminId,
      adminCookie, """{"role":"member"}""")
    check demoteLast == 409
    let previousRole = database.queryOne(
      """select role from community.membership
         where community_id = $1::uuid and user_id = $2::uuid""",
      @[textParam(clubId), textParam(memberId)]).get.get("role")
    let (promoted, _) = call(HttpPatch, "/c/http-club/members/" & memberId,
      adminCookie, """{"role":"admin"}""")
    check promoted == 200
    let roleRow = database.queryOne(
      """select after from account.audit
         where action = 'community.member.role' and target_id = $1
           and community_id = $2::uuid
         order by occurred_at desc limit 1""",
      @[textParam(memberId), textParam(clubId)])
    check roleRow.isSome
    let roleEvidence = parseJson(roleRow.get.get("after"))
    check roleEvidence["fromRole"].getStr() == previousRole
    check roleEvidence["toRole"].getStr() == "admin"
    let (removed, _) = call(HttpDelete, "/c/http-club/members/" & memberId,
      adminCookie)
    check removed == 204
    check not membership.list(database, clubId).anyIt(it.userId == memberId)

  test "version reports the build without a session":
    let (status, body) = call(HttpGet, "/version")
    check status == 200
    let info = parseJson(body)
    check info["version"].getStr() == expectedVersion
    check info["commit"].getStr().len > 0

  test "config exposes effective values to every member":
    # Every member screen reads this (export sizes, page limits). Making it
    # admin-only left a plain member's community page broken with a 403.
    discard membership.add(database, clubId, memberId, "member")
    let (memberStatus, memberBody) = call(HttpGet, "/c/http-club/config", memberCookie)
    check memberStatus == 200
    let memberConfig = parseJson(memberBody)["effective"]
    check memberConfig["community.invite_ttl_days"]["source"].getStr() == "platform"
    # Security and session keys are platform-scope, so the community view must
    # not carry them: every member can read this endpoint.
    check not memberConfig.hasKey("security.allowed_origins")
    check not memberConfig.hasKey("session.absolute_days")
    let (adminStatus, body) = call(HttpGet, "/c/http-club/config", adminCookie)
    check adminStatus == 200
    check parseJson(body)["effective"]["community.invite_ttl_days"]["source"].getStr() ==
      "platform"
    let (anonymous, _) = call(HttpGet, "/c/http-club/config")
    check anonymous == 401

  test "a wrong verb on a known shape answers 405, not 404":
    # 404 is reserved for a community the caller cannot see; a client that used
    # the wrong verb must be told the route exists.
    let (sessions, _) = call(HttpPut, "/c/http-club/sessions", adminCookie)
    check sessions == 405
    let (players, _) = call(HttpPatch, "/c/http-club/players", adminCookie)
    check players == 405
    let (bogus, _) = call(HttpGet, "/c/http-club/sessions/1/bogus", adminCookie)
    check bogus == 404

  test "an admin narrows a community setting, nobody widens it":
    let (asMember, _) = call(HttpPatch, "/c/http-club/settings", memberCookie,
      """{"community.invite_ttl_days": 3}""")
    check asMember == 403
    let (unknown, _) = call(HttpPatch, "/c/http-club/settings", adminCookie,
      """{"nope.value": 1}""")
    check unknown == 400
    # The platform value is the ceiling: 365 is above the seeded 7.
    let (wide, _) = call(HttpPatch, "/c/http-club/settings", adminCookie,
      """{"community.invite_ttl_days": 365}""")
    check wide == 400
    let (wrongType, _) = call(HttpPatch, "/c/http-club/settings", adminCookie,
      """{"community.invite_ttl_days": "three"}""")
    check wrongType == 400
    let (okStatus, okBody) = call(HttpPatch, "/c/http-club/settings", adminCookie,
      """{"community.invite_ttl_days": 3}""")
    check okStatus == 200
    check parseJson(okBody)["values"]["community.invite_ttl_days"].getInt() == 3
    # The member read uses /config, and it carries the new source.
    let (readStatus, readBody) = call(HttpGet, "/c/http-club/config", memberCookie)
    check readStatus == 200
    let applied = parseJson(readBody)["effective"]["community.invite_ttl_days"]
    check applied["value"].getInt() == 3
    check applied["source"].getStr() == "community"
    # Other tests expect the platform value.
    discard database.execUpdate(
      "delete from community.settings where community_id = $1::uuid",
      @[textParam(clubId)])
