import std/[json, options, strutils, unittest]
import db/db
import community/infrastructure/community_store
import tests/fixtures
import ../http_support

const
  port = testPort(18093)
  baseUrl = "http://127.0.0.1:" & $uint16(port)

var
  database: Db
  communityId: string
  adminCookie, admin2Cookie, memberCookie, otherCookie: string
  adminId: string

proc freshMember(sub: string): string =
  let id = newUser(database, sub, sub, sub)
  newMember(database, communityId, id, "member")
  cookieFor(database, id)

proc player(name: string): string =
  let response = call(baseUrl, HttpPost, "/c/claim-club/players", adminCookie,
    "{\"name\":\"" & name & "\"}")
  doAssert response.status == 201, response.body
  parseJson(response.body)["id"].getStr()

proc bootstrap() =
  database = openDb(dsn(), 1)
  purgeCommunity(database, "claim-club")
  discard database.execUpdate(
    "delete from platform.user where google_sub like 'claim-%'")
  let ownerId = newUser(database, "claim-owner", "claim-owner-hash", "Owner",
    owner = true)
  communityId = community_store.create(database, "claim-club", "Claim Club",
    "claim-admin@example.com", "Asia/Jakarta", ownerId).communityId
  proc member(sub, role: string): string =
    let id = newUser(database, sub, sub, sub)
    newMember(database, communityId, id, role)
    id
  adminId = member("claim-admin", "admin")
  let admin2Id = member("claim-admin2", "admin")
  let memberId = member("claim-member", "member")
  let otherId = member("claim-other", "member")
  adminCookie = cookieFor(database, adminId)
  admin2Cookie = cookieFor(database, admin2Id)
  memberCookie = cookieFor(database, memberId)
  otherCookie = cookieFor(database, otherId)

  startServer(newTestApp(database), port, baseUrl)

bootstrap()

suite "claim HTTP":
  test "a claim is pending, single while pending, and decided by an admin":
    let playerId = player("Klaim Satu")
    let submitted = call(baseUrl, HttpPost,
      "/c/claim-club/players/" & playerId & "/claims", memberCookie)
    expectStatus(submitted, 201)
    let duplicate = call(baseUrl, HttpPost,
      "/c/claim-club/players/" & playerId & "/claims", otherCookie)
    expectProblem(duplicate, 409)
    let list = call(baseUrl, HttpGet,
      "/c/claim-club/players/" & playerId & "/claims", adminCookie)
    let listBody = list.body
    expectStatus(list, 200)
    let claimId = parseJson(listBody)["items"][0]["id"].getStr()
    let byMember = call(baseUrl, HttpPatch,
      "/c/claim-club/players/" & playerId & "/claims/" & claimId, memberCookie,
      """{"decision":"approve"}""")
    expectProblem(byMember, 403)
    let approved = call(baseUrl, HttpPatch,
      "/c/claim-club/players/" & playerId & "/claims/" & claimId, adminCookie,
      """{"decision":"approve"}""")
    expectStatus(approved, 200)
    let bound = call(baseUrl, HttpGet,
      "/c/claim-club/players/" & playerId, adminCookie)
    let boundBody = bound.body
    expectStatus(bound, 200)
    check parseJson(boundBody)["userId"].kind == JString

  test "an admin cannot decide a claim they filed":
    let playerId = player("Klaim Dua")
    let submitted = call(baseUrl, HttpPost,
      "/c/claim-club/players/" & playerId & "/claims", admin2Cookie)
    expectStatus(submitted, 201)
    let listBody = call(baseUrl, HttpGet,
      "/c/claim-club/players/" & playerId & "/claims", adminCookie).body
    let claimId = parseJson(listBody)["items"][0]["id"].getStr()
    let selfDecision = call(baseUrl, HttpPatch,
      "/c/claim-club/players/" & playerId & "/claims/" & claimId, admin2Cookie,
      """{"decision":"approve"}""")
    expectProblem(selfDecision, 403)

  test "only one pending claim exists per player":
    let playerId = player("Klaim Tiga")
    let first = freshMember("claim-tiga-a")
    let second = freshMember("claim-tiga-b")
    let accepted = call(baseUrl, HttpPost,
      "/c/claim-club/players/" & playerId & "/claims", first)
    expectStatus(accepted, 201)
    let queuedBehind = call(baseUrl, HttpPost,
      "/c/claim-club/players/" & playerId & "/claims", second)
    expectProblem(queuedBehind, 409)
    let listBody = call(baseUrl, HttpGet,
      "/c/claim-club/players/" & playerId & "/claims", adminCookie).body
    let items = parseJson(listBody)["items"]
    check items.len == 1
    let claimId = items[0]["id"].getStr()
    discard call(baseUrl, HttpPatch, "/c/claim-club/players/" & playerId & "/claims/" &
      claimId, adminCookie, """{"decision":"approve"}""")
    # Once claimed, nobody else can even file.
    let afterApproval = call(baseUrl, HttpPost,
      "/c/claim-club/players/" & playerId & "/claims", second)
    expectProblem(afterApproval, 409)

  test "the owner can release and another account can claim again":
    let playerId = player("Klaim Empat")
    let owner = freshMember("claim-empat")
    discard call(baseUrl, HttpPost, "/c/claim-club/players/" & playerId & "/claims", owner)
    let listBody = call(baseUrl, HttpGet,
      "/c/claim-club/players/" & playerId & "/claims", adminCookie).body
    let claimId = parseJson(listBody)["items"][0]["id"].getStr()
    discard call(baseUrl, HttpPatch, "/c/claim-club/players/" & playerId & "/claims/" &
      claimId, adminCookie, """{"decision":"approve"}""")
    let released = call(baseUrl, HttpDelete,
      "/c/claim-club/players/" & playerId & "/claim", owner)
    let releasedBody = released.body
    expectStatus(released, 200)
    check parseJson(releasedBody)["status"].getStr() == "released"
    let unbound = call(baseUrl, HttpGet,
      "/c/claim-club/players/" & playerId, adminCookie)
    let unbindBody = unbound.body
    check unbindBody.contains("\"userId\":null")
    let again = call(baseUrl, HttpPost,
      "/c/claim-club/players/" & playerId & "/claims",
      freshMember("claim-empat-again"))
    expectStatus(again, 201)

  test "an admin release needs a reason and reports a stale claim as 409":
    let playerId = player("Klaim Lima")
    discard call(baseUrl, HttpPost, "/c/claim-club/players/" & playerId & "/claims",
      freshMember("claim-lima"))
    let listBody = call(baseUrl, HttpGet,
      "/c/claim-club/players/" & playerId & "/claims", adminCookie).body
    let claimId = parseJson(listBody)["items"][0]["id"].getStr()
    discard call(baseUrl, HttpPatch, "/c/claim-club/players/" & playerId & "/claims/" &
      claimId, adminCookie, """{"decision":"approve"}""")
    let noReason = call(baseUrl, HttpPatch, "/c/claim-club/players/" & playerId &
      "/claims/" & claimId, adminCookie, """{"action":"release"}""")
    expectProblem(noReason, 400)
    let released = call(baseUrl, HttpPatch, "/c/claim-club/players/" & playerId &
      "/claims/" & claimId, adminCookie,
      """{"action":"release","reason":"account transfer"}""")
    expectStatus(released, 200)
    let twice = call(baseUrl, HttpPatch, "/c/claim-club/players/" & playerId &
      "/claims/" & claimId, adminCookie,
      """{"action":"release","reason":"again"}""")
    expectProblem(twice, 409)

  test "a second approval for the same member closes instead of dangling":
    let claimant = freshMember("claim-two-players")
    let firstPlayer = player("Klaim Empat A")
    let secondPlayer = player("Klaim Empat B")
    discard call(baseUrl, HttpPost, "/c/claim-club/players/" & firstPlayer & "/claims",
      claimant)
    discard call(baseUrl, HttpPost, "/c/claim-club/players/" & secondPlayer & "/claims",
      claimant)
    let firstList = call(baseUrl, HttpGet,
      "/c/claim-club/players/" & firstPlayer & "/claims", adminCookie).body
    let firstClaim = parseJson(firstList)["items"][0]["id"].getStr()
    let firstApproved = call(baseUrl, HttpPatch,
      "/c/claim-club/players/" & firstPlayer & "/claims/" & firstClaim,
      adminCookie, """{"decision":"approve"}""")
    expectStatus(firstApproved, 200)

    let secondList = call(baseUrl, HttpGet,
      "/c/claim-club/players/" & secondPlayer & "/claims", adminCookie).body
    let secondClaim = parseJson(secondList)["items"][0]["id"].getStr()
    let refused = call(baseUrl, HttpPatch,
      "/c/claim-club/players/" & secondPlayer & "/claims/" & secondClaim,
      adminCookie, """{"decision":"approve"}""")
    let refusedBody = refused.body
    expectProblem(refused, 409)
    check parseJson(refusedBody)["code"].getStr() == "CLAIMANT_OWNS_PLAYER"
    # The refused claim is closed, so it cannot stay pending forever.
    let afterList = call(baseUrl, HttpGet,
      "/c/claim-club/players/" & secondPlayer & "/claims", adminCookie).body
    check parseJson(afterList)["items"][0]["status"].getStr() == "rejected"
    check parseJson(afterList)["items"][0]["reason"].getStr() == "already_claimed"

  test "a member sees the claim trail without another member's identity":
    let playerId = player("Klaim Enam")
    let applicant = freshMember("claim-enam-a")
    let bystander = freshMember("claim-enam-b")
    discard call(baseUrl, HttpPost, "/c/claim-club/players/" & playerId & "/claims",
      applicant)
    let adminList = call(baseUrl, HttpGet,
      "/c/claim-club/players/" & playerId & "/claims", adminCookie).body
    let claimId = parseJson(adminList)["items"][0]["id"].getStr()
    let approved = call(baseUrl, HttpPatch, "/c/claim-club/players/" & playerId &
      "/claims/" & claimId, adminCookie,
      """{"decision":"approve","reason":"verified at the club"}""")
    expectStatus(approved, 200)

    # The filing member still recognises their own decision and reason.
    let ownBody = call(baseUrl, HttpGet,
      "/c/claim-club/players/" & playerId & "/claims", applicant).body
    let own = parseJson(ownBody)["items"][0]
    check own["userId"].getStr().len > 0
    check own["decidedBy"].getStr().len > 0
    check own["reason"].getStr() == "verified at the club"

    # Anyone else sees that the player is claimed, not who claimed it.
    let otherStatus = call(baseUrl, HttpGet,
      "/c/claim-club/players/" & playerId & "/claims", bystander)
    let otherBody = otherStatus.body
    expectStatus(otherStatus, 200)
    let seen = parseJson(otherBody)["items"][0]
    check seen["id"].getStr() == claimId
    check seen["status"].getStr() == "approved"
    check seen["userId"].getStr() == ""
    check seen["decidedBy"].getStr() == ""
    check seen["reason"].getStr() == ""

  test "mine returns the player the account owns":
    let minePlayer = player("Klaim Delapan Punya")
    let owner = freshMember("claim-delapan")
    discard call(baseUrl, HttpPost, "/c/claim-club/players/" & minePlayer & "/claims",
      owner)
    let listBody = call(baseUrl, HttpGet,
      "/c/claim-club/players/" & minePlayer & "/claims", adminCookie).body
    let claimId = parseJson(listBody)["items"][0]["id"].getStr()
    let approved = call(baseUrl, HttpPatch,
      "/c/claim-club/players/" & minePlayer & "/claims/" & claimId, adminCookie,
      """{"decision":"approve"}""")
    expectStatus(approved, 200)

    let status = call(baseUrl, HttpGet, "/c/claim-club/players?mine=1", owner)
    let body = status.body
    expectStatus(status, 200)
    let items = parseJson(body)["items"]
    check items.len == 1
    check items[0]["id"].getStr() == minePlayer

    let emptyStatus = call(baseUrl, HttpGet, "/c/claim-club/players?mine=1",
      freshMember("claim-delapan-bebas"))
    let emptyBody = emptyStatus.body
    expectStatus(emptyStatus, 200)
    check parseJson(emptyBody)["items"].len == 0

  test "a player response says whether the viewer already owns a player":
    let ownedPlayer = player("Klaim Tujuh Punya")
    let openPlayer = player("Klaim Tujuh Terbuka")
    let owner = freshMember("claim-tujuh")
    discard call(baseUrl, HttpPost, "/c/claim-club/players/" & ownedPlayer & "/claims",
      owner)
    let listBody = call(baseUrl, HttpGet,
      "/c/claim-club/players/" & ownedPlayer & "/claims", adminCookie).body
    let claimId = parseJson(listBody)["items"][0]["id"].getStr()
    let approved = call(baseUrl, HttpPatch,
      "/c/claim-club/players/" & ownedPlayer & "/claims/" & claimId, adminCookie,
      """{"decision":"approve"}""")
    expectStatus(approved, 200)

    # The owner sees the flag on a different, still unclaimed player: the claim
    # button there would be refused, so the page must not offer it.
    let ownedStatus = call(baseUrl, HttpGet,
      "/c/claim-club/players/" & openPlayer, owner)
    let ownedBody = ownedStatus.body
    expectStatus(ownedStatus, 200)
    check parseJson(ownedBody)["viewerOwnsPlayer"].kind == JBool
    check parseJson(ownedBody)["viewerOwnsPlayer"].getBool()
    check parseJson(ownedBody)["userId"].kind == JNull

    # A member who owns nothing keeps the action.
    let freeStatus = call(baseUrl, HttpGet,
      "/c/claim-club/players/" & openPlayer, freshMember("claim-tujuh-bebas"))
    let freeBody = freeStatus.body
    expectStatus(freeStatus, 200)
    check not parseJson(freeBody)["viewerOwnsPlayer"].getBool()

  test "the admin queue lists pending claims oldest first with the claimant":
    # Earlier tests leave a pending claim behind; the queue spans the community,
    # so start from an empty ledger to assert on its exact contents.
    discard database.execUpdate(
      "delete from player.claims where community_id = $1::uuid",
      @[textParam(communityId)])
    let olderPlayer = player("Klaim Antrean Lama")
    let newerPlayer = player("Klaim Antrean Baru")
    let boundPlayer = player("Klaim Antrean Disetujui")
    let olderClaimant = freshMember("claim-antrean-lama")
    let newerClaimant = freshMember("claim-antrean-baru")
    let boundClaimant = freshMember("claim-antrean-disetujui")
    let olderSubmitted = call(baseUrl, HttpPost,
      "/c/claim-club/players/" & olderPlayer & "/claims", olderClaimant)
    expectStatus(olderSubmitted, 201)
    let newerSubmitted = call(baseUrl, HttpPost,
      "/c/claim-club/players/" & newerPlayer & "/claims", newerClaimant)
    expectStatus(newerSubmitted, 201)
    let boundSubmitted = call(baseUrl, HttpPost,
      "/c/claim-club/players/" & boundPlayer & "/claims", boundClaimant)
    expectStatus(boundSubmitted, 201)

    # The claim row is the ordering key; distinct timestamps keep it stable.
    discard database.execUpdate(
      """update player.claims set created_at = now() - interval '2 hours'
         where community_id = $1::uuid and player_id = $2::uuid""",
      @[textParam(communityId), textParam(olderPlayer)])
    discard database.execUpdate(
      """update player.claims set created_at = now() - interval '1 hour'
         where community_id = $1::uuid and player_id = $2::uuid""",
      @[textParam(communityId), textParam(newerPlayer)])

    let boundClaim = database.queryOne(
      """select id from player.claims
         where community_id = $1::uuid and player_id = $2::uuid""",
      @[textParam(communityId), textParam(boundPlayer)]).get.get("id")
    let bound = call(baseUrl, HttpPatch, "/c/claim-club/players/" & boundPlayer &
      "/claims/" & boundClaim, adminCookie, """{"decision":"approve"}""")
    expectStatus(bound, 200)

    let status = call(baseUrl, HttpGet, "/c/claim-club/claims", adminCookie)
    let body = status.body
    expectStatus(status, 200)
    let items = parseJson(body)["items"]
    check items.len == 2
    check items[0]["playerId"].getStr() == olderPlayer
    check items[0]["playerName"].getStr() == "Klaim Antrean Lama"
    check items[0]["displayName"].getStr() == "claim-antrean-lama"
    check items[0]["createdAt"].getStr().len > 0
    check items[1]["playerId"].getStr() == newerPlayer
    check items[1]["displayName"].getStr() == "claim-antrean-baru"

    let byMember = call(baseUrl, HttpGet, "/c/claim-club/claims", memberCookie)
    expectProblem(byMember, 403)
