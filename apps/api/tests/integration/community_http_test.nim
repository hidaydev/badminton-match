import std/[httpclient, json, options, sequtils, strutils, unittest]
import db/db
import account/domain/roles
import community/infrastructure/[community_store, membership]
import tests/fixtures
import ../http_support

const expectedVersion = staticRead("../../../../VERSION").strip()

let
  port = testPort()
  baseUrl = "http://127.0.0.1:" & $uint16(port)
  ownerEmail = "http-owner@example.com"
  adminEmail = "http-admin@example.com"
  memberEmail = "http-member@example.com"

var
  database: Db
  ownerId, adminId, memberId: string
  ownerCookie, adminCookie, memberCookie: string
  clubId, closedId: string
  # The reads BE-05 owns get their own communities, users and sessions so the
  # cases above can mutate the http-club fixture without changing the answer.
  be05ClubId, be05OtherId: string
  be05AdminCookie, be05MemberCookie, be05SoloCookie: string

proc bootstrap() =
  database = openDb(dsn(), 1)
  for slug in ["http-club", "http-closed"]:
    purgeCommunity(database, slug)
  discard database.execUpdate("delete from platform.user where google_sub like 'http-%'")
  ownerId = newUser(database, "http-owner", ownerEmail, "http-owner", owner = true)
  adminId = newUser(database, "http-admin", adminEmail, "http-admin")
  memberId = newUser(database, "http-member", memberEmail, "http-member")
  clubId = community_store.create(database, "http-club", "HTTP Club", adminEmail,
    "Asia/Jakarta", ownerId).communityId
  closedId = community_store.create(database, "http-closed", "HTTP Closed",
    adminEmail, "Asia/Jakarta", ownerId).communityId
  newMember(database, clubId, adminId, "admin")
  newMember(database, closedId, adminId, "admin")
  ownerCookie = cookieFor(database, ownerId)
  adminCookie = cookieFor(database, adminId)
  memberCookie = cookieFor(database, memberId)

  for slug in ["be05-club", "be05-other"]:
    purgeCommunity(database, slug)
  cleanupUsers(database, "be05-%")
  let be05AdminId = newUser(database, "be05-admin",
    "be05-admin@example.com", "BE05 Admin")
  let be05MemberId = newUser(database, "be05-member",
    "be05-member@example.com", "BE05 Member")
  let be05SoloId = newUser(database, "be05-solo", "be05-solo@example.com",
    "BE05 Solo")
  be05ClubId = newCommunity(database, "be05-club", "BE05 Club")
  be05OtherId = newCommunity(database, "be05-other", "BE05 Other")
  newMember(database, be05ClubId, be05AdminId, "admin")
  newMember(database, be05ClubId, be05MemberId, "member")
  newMember(database, be05OtherId, be05AdminId, "admin")
  be05AdminCookie = cookieFor(database, be05AdminId)
  be05MemberCookie = cookieFor(database, be05MemberId)
  be05SoloCookie = cookieFor(database, be05SoloId)

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
    discard membership.add(database, clubId, memberId, rMember)
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

  test "the settings read carries only community keys with a source":
    # An old row may hold a platform key written before the scope was enforced:
    # every member can read this route, so it must not resurface here.
    discard database.execUpdate(
      """insert into community.settings (community_id, values, updated_at)
         values ($1::uuid, $2::jsonb, now())
         on conflict (community_id) do update
           set values = excluded.values""",
      @[textParam(be05ClubId), textParam("""{"community.invite_ttl_days": 3,
        "community.directory_enabled": true,
        "session.absolute_days": 30}""")])
    let memberStatus = call(baseUrl, HttpGet, "/c/be05-club/settings",
      be05MemberCookie)
    let memberBody = memberStatus.body
    expectStatus(memberStatus, 200)
    let member = parseJson(memberBody)
    let values = member["values"]
    check values.len == 2
    check values["community.invite_ttl_days"].getInt() == 3
    check values["community.directory_enabled"].getBool()
    check not values.hasKey("session.absolute_days")
    let effective = member["effective"]
    check effective["community.invite_ttl_days"]["value"].getInt() == 3
    check effective["community.invite_ttl_days"]["source"].getStr() == "community"
    # Only a boolean carries the widening flag, and only the opt-in ones may
    # leave the platform default alone.
    check not effective["community.invite_ttl_days"].hasKey("widenable")
    check effective["community.directory_enabled"]["value"].getBool()
    check effective["community.directory_enabled"]["source"].getStr() == "community"
    check effective["community.directory_enabled"]["widenable"].getBool()
    check effective["community.join_requests_enabled"]["widenable"].getBool()
    # A key with no stored override reports where its value really came from.
    check effective["rating.score_target"]["source"].getStr() == "platform"
    check not effective.hasKey("security.allowed_origins")
    check not effective.hasKey("api.page_size_default")
    let adminStatus = call(baseUrl, HttpGet, "/c/be05-club/settings",
      be05AdminCookie)
    let adminBody = adminStatus.body
    expectStatus(adminStatus, 200)
    let admin = parseJson(adminBody)
    check admin["values"]["community.invite_ttl_days"].getInt() == 3
    check admin["effective"]["community.directory_enabled"]["source"].getStr() ==
      "community"
    let anonymous = call(baseUrl, HttpGet, "/c/be05-club/settings")
    expectProblem(anonymous, 401)
    # A member of another community is answered as if this one did not exist.
    let foreign = call(baseUrl, HttpGet, "/c/be05-other/settings",
      be05MemberCookie)
    expectProblem(foreign, 404)
    discard database.execUpdate(
      "delete from community.settings where community_id = $1::uuid",
      @[textParam(be05ClubId)])

  test "the community list is the caller's own memberships":
    let status = call(baseUrl, HttpGet, "/communities", be05MemberCookie)
    let body = status.body
    expectStatus(status, 200)
    let items = parseJson(body)["items"]
    check items.len == 1
    check items[0]["id"].getStr() == be05ClubId
    check items[0]["slug"].getStr() == "be05-club"
    check items[0]["name"].getStr() == "BE05 Club"
    check items[0]["role"].getStr() == "member"
    # The admin belongs to both, so the list is the caller's rows, not the
    # community table.
    let adminStatus = call(baseUrl, HttpGet, "/communities", be05AdminCookie)
    let adminBody = adminStatus.body
    expectStatus(adminStatus, 200)
    let adminItems = parseJson(adminBody)["items"]
    check adminItems.len == 2
    var slugs: seq[string] = @[]
    for item in adminItems:
      check item["role"].getStr() == "admin"
      slugs.add(item["slug"].getStr())
    check "be05-club" in slugs
    check "be05-other" in slugs
    # A member of A is never told that B exists.
    check "be05-other" notin body
    # No membership is an empty list, not an error.
    let soloStatus = call(baseUrl, HttpGet, "/communities", be05SoloCookie)
    let soloBody = soloStatus.body
    expectStatus(soloStatus, 200)
    check parseJson(soloBody)["items"].len == 0
    let anonymous = call(baseUrl, HttpGet, "/communities")
    expectProblem(anonymous, 401)
    for slug in ["be05-club", "be05-other"]:
      purgeCommunity(database, slug)
    cleanupUsers(database, "be05-%")
