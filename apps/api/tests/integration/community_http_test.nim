import std/[httpclient, json, options, os, sequtils, strutils, unittest]
import db/db
import sha256
import community/infrastructure/[community_store, membership]
import ../http_support

const
  port = testPort(18091)
  baseUrl = "http://127.0.0.1:" & $uint16(port)
  ownerEmail = "http-owner@example.com"
  adminEmail = "http-admin@example.com"
  memberEmail = "http-member@example.com"
  expectedVersion = staticRead("../../../../VERSION").strip()

var
  database: Db
  ownerId, adminId, memberId: string
  ownerCookie, adminCookie, memberCookie: string
  clubId, closedId: string

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
  ownerCookie = cookieFor(database, ownerId)
  adminCookie = cookieFor(database, adminId)
  memberCookie = cookieFor(database, memberId)

  startServer(newTestApp(database), port, baseUrl)

bootstrap()

suite "community HTTP":
  test "only the platform owner creates a community, and it needs an admin email":
    let anonymous = call(baseUrl, HttpPost, "/communities",
      body = """{"slug":"http-new","name":"New","adminEmail":"x@example.com"}""")
    expectProblem(anonymous, 401)
    let notOwner = call(baseUrl, HttpPost, "/communities", adminCookie,
      """{"slug":"http-new","name":"New","adminEmail":"x@example.com"}""")
    expectProblem(notOwner, 403)
    let noEmail = call(baseUrl, HttpPost, "/communities", ownerCookie,
      """{"slug":"http-new","name":"New"}""")
    expectProblem(noEmail, 400)
    let badSlug = call(baseUrl, HttpPost, "/communities", ownerCookie,
      """{"slug":"a/b","name":"New","adminEmail":"x@example.com"}""")
    expectProblem(badSlug, 400)
    let created = call(baseUrl, HttpPost, "/communities", ownerCookie,
      """{"slug":"http-new","name":"New","adminEmail":"new@example.com"}""")
    let body = created.body
    expectStatus(created, 201)
    check parseJson(body)["timezone"].getStr() == "Asia/Jakarta"
    let duplicate = call(baseUrl, HttpPost, "/communities", ownerCookie,
      """{"slug":"http-new","name":"Again","adminEmail":"new@example.com"}""")
    expectProblem(duplicate, 409)

  test "the directory shows only opted-in communities to outsiders":
    discard database.execUpdate(
      "delete from platform.community where slug = 'http-new'")
    let anonymousStatus = call(baseUrl, HttpGet, "/directory")
    let anonymousBody = anonymousStatus.body
    expectStatus(anonymousStatus, 200)
    check "http-club" notin anonymousBody
    discard database.execUpdate(
      """insert into community.settings (community_id, values)
         values ($1::uuid, '{"community.directory_enabled": true}')
         on conflict (community_id) do update set values = excluded.values""",
      @[textParam(clubId)])
    let status = call(baseUrl, HttpGet, "/directory")
    let body = status.body
    expectStatus(status, 200)
    let items = parseJson(body)["items"]
    var entry: JsonNode
    for item in items:
      if item["slug"].getStr() == "http-club":
        entry = item
    check entry.len == 2
    check entry["name"].getStr() == "HTTP Club"

  test "an invitation is bound to the address and single use":
    let inviteStatus = call(baseUrl, HttpPost, "/c/http-club/invites",
      adminCookie, "{\"email\":\"" & memberEmail & "\",\"role\":\"host\"}")
    let inviteBody = inviteStatus.body
    expectStatus(inviteStatus, 201)
    let token = parseJson(inviteBody)["token"].getStr()
    let wrong = call(baseUrl, HttpPost, "/invites/" & token & "/accept", adminCookie)
    expectProblem(wrong, 403)
    let accepted = call(baseUrl, HttpPost, "/invites/" & token & "/accept",
      memberCookie)
    let acceptedBody = accepted.body
    expectStatus(accepted, 201)
    check parseJson(acceptedBody)["role"].getStr() == "host"
    # Login auto-accepts the invite for its address, so a later click reports
    # the same membership instead of a misleading "already used".
    let reused = call(baseUrl, HttpPost, "/invites/" & token & "/accept",
      memberCookie)
    let reusedBody = reused.body
    expectStatus(reused, 201)
    check parseJson(reusedBody)["role"].getStr() == "host"
    # Another account cannot reuse the token.
    let stolen = call(baseUrl, HttpPost, "/invites/" & token & "/accept", adminCookie)
    expectProblem(stolen, 403)
    check membership.list(database, clubId).anyIt(it.userId == memberId)

  test "join requests answer identically and are decided once":
    let missing = call(baseUrl, HttpPost, "/c/nope/join-requests",
      memberCookie)
    let missingBody = missing.body
    let disabled = call(baseUrl, HttpPost, "/c/http-closed/join-requests",
      memberCookie)
    let disabledBody = disabled.body
    expectStatus(missing, 202)
    check missingBody == disabledBody
    discard database.execUpdate(
      """insert into community.settings (community_id, values)
         values ($1::uuid, '{"community.join_requests_enabled": true}')
         on conflict (community_id) do update set values = excluded.values""",
      @[textParam(closedId)])
    let pending = call(baseUrl, HttpPost, "/c/http-closed/join-requests",
      memberCookie)
    let pendingBody = pending.body
    let again = call(baseUrl, HttpPost, "/c/http-closed/join-requests",
      memberCookie)
    let againBody = again.body
    expectStatus(pending, 202)
    check againBody == pendingBody
    let requestAudit = database.queryOne(
      """select after from account.audit
         where action = 'community.join.requested' and target_id = $1
           and community_id = $2::uuid
         order by occurred_at desc limit 1""",
      @[textParam(memberId), textParam(closedId)])
    check requestAudit.isSome
    let listStatus = call(baseUrl, HttpGet, "/c/http-closed/join-requests",
      adminCookie)
    let listBody = listStatus.body
    expectStatus(listStatus, 200)
    let items = parseJson(listBody)["items"]
    check items.len == 1
    let requestId = items[0]["id"].getStr()
    let decided = call(baseUrl, HttpPatch, "/c/http-closed/join-requests/" & requestId,
      adminCookie, """{"decision":"approve"}""")
    expectStatus(decided, 200)
    let twice = call(baseUrl, HttpPatch, "/c/http-closed/join-requests/" & requestId,
      adminCookie, """{"decision":"approve"}""")
    expectProblem(twice, 404)
    check membership.list(database, closedId).anyIt(it.userId == memberId)

  test "role changes are admin-only and never remove the last admin":
    let forbidden = call(baseUrl, HttpGet, "/c/http-club/members", memberCookie)
    expectStatus(forbidden, 200)
    let patchAsMember = call(baseUrl, HttpPatch,
      "/c/http-club/members/" & memberId, memberCookie, """{"role":"admin"}""")
    expectProblem(patchAsMember, 403)
    let demoteLast = call(baseUrl, HttpPatch, "/c/http-club/members/" & adminId,
      adminCookie, """{"role":"member"}""")
    expectProblem(demoteLast, 409)
    let previousRole = database.queryOne(
      """select role from community.membership
         where community_id = $1::uuid and user_id = $2::uuid""",
      @[textParam(clubId), textParam(memberId)]).get.get("role")
    let promoted = call(baseUrl, HttpPatch, "/c/http-club/members/" & memberId,
      adminCookie, """{"role":"admin"}""")
    expectStatus(promoted, 200)
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
    let removed = call(baseUrl, HttpDelete, "/c/http-club/members/" & memberId,
      adminCookie)
    expectStatus(removed, 204)
    check not membership.list(database, clubId).anyIt(it.userId == memberId)

  test "version reports the build without a session":
    let status = call(baseUrl, HttpGet, "/version")
    let body = status.body
    expectStatus(status, 200)
    let info = parseJson(body)
    check info["version"].getStr() == expectedVersion
    check info["commit"].getStr().len > 0

  test "config exposes effective values to every member":
    # Every member screen reads this (export sizes, page limits). Making it
    # admin-only left a plain member's community page broken with a 403.
    discard membership.add(database, clubId, memberId, "member")
    let memberStatus = call(baseUrl, HttpGet, "/c/http-club/config", memberCookie)
    let memberBody = memberStatus.body
    expectStatus(memberStatus, 200)
    let memberConfig = parseJson(memberBody)["effective"]
    check memberConfig["community.invite_ttl_days"]["source"].getStr() == "platform"
    # Security and session keys are platform-scope, so the community view must
    # not carry them: every member can read this endpoint.
    check not memberConfig.hasKey("security.allowed_origins")
    check not memberConfig.hasKey("session.absolute_days")
    let adminStatus = call(baseUrl, HttpGet, "/c/http-club/config", adminCookie)
    let body = adminStatus.body
    expectStatus(adminStatus, 200)
    check parseJson(body)["effective"]["community.invite_ttl_days"]["source"].getStr() ==
      "platform"
    let anonymous = call(baseUrl, HttpGet, "/c/http-club/config")
    expectProblem(anonymous, 401)

  test "a wrong verb on a known shape answers 405, not 404":
    # 404 is reserved for a community the caller cannot see; a client that used
    # the wrong verb must be told the route exists.
    let sessions = call(baseUrl, HttpPut, "/c/http-club/sessions", adminCookie)
    expectProblem(sessions, 405)
    let players = call(baseUrl, HttpPatch, "/c/http-club/players", adminCookie)
    expectProblem(players, 405)
    let bogus = call(baseUrl, HttpGet, "/c/http-club/sessions/1/bogus", adminCookie)
    expectProblem(bogus, 404)

  test "an admin narrows a community setting, nobody widens it":
    let asMember = call(baseUrl, HttpPatch, "/c/http-club/settings", memberCookie,
      """{"community.invite_ttl_days": 3}""")
    expectProblem(asMember, 403)
    let unknown = call(baseUrl, HttpPatch, "/c/http-club/settings", adminCookie,
      """{"nope.value": 1}""")
    expectProblem(unknown, 400)
    # The platform value is the ceiling: 365 is above the seeded 7.
    let wide = call(baseUrl, HttpPatch, "/c/http-club/settings", adminCookie,
      """{"community.invite_ttl_days": 365}""")
    expectProblem(wide, 400)
    let wrongType = call(baseUrl, HttpPatch, "/c/http-club/settings", adminCookie,
      """{"community.invite_ttl_days": "three"}""")
    expectProblem(wrongType, 400)
    let okStatus = call(baseUrl, HttpPatch, "/c/http-club/settings", adminCookie,
      """{"community.invite_ttl_days": 3}""")
    let okBody = okStatus.body
    expectStatus(okStatus, 200)
    check parseJson(okBody)["values"]["community.invite_ttl_days"].getInt() == 3
    # The member read uses /config, and it carries the new source.
    let readStatus = call(baseUrl, HttpGet, "/c/http-club/config", memberCookie)
    let readBody = readStatus.body
    expectStatus(readStatus, 200)
    let applied = parseJson(readBody)["effective"]["community.invite_ttl_days"]
    check applied["value"].getInt() == 3
    check applied["source"].getStr() == "community"
    # Other tests expect the platform value.
    discard database.execUpdate(
      "delete from community.settings where community_id = $1::uuid",
      @[textParam(clubId)])
