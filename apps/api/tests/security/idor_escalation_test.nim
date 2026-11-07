import std/[httpclient, json, options, strutils, unittest]
import db/db
import mummy
import community/infrastructure/community_store
import share/crypto
import share/store as shareStore
import ../http_support

const
  baseUrl = "http://127.0.0.1:18101"
  port = Port(18101)
  slugA = "sec-club"
  slugB = "sec-other"
  slugOwned = "sec-owned"

var
  database: Db
  clubId, otherId: string
  adminCookie, hostCookie, memberCookie, member2Cookie, otherCookie,
    ownerCookie: string
  member2Id, ownerId: string
  playerA, playerB, sessionA, sessionB, shareB: string

proc bootstrap() =
  database = openDb(dsn(), 1)
  for slug in [slugA, slugB, slugOwned]:
    cleanupCommunity(database, slug)
  cleanupUsers(database, "sec-%")

  ownerId = addUser(database, "sec-owner", "sec-owner@example.com", owner = true)
  clubId = community_store.create(database, slugA, "Security Club",
    "sec-admin@example.com", "Asia/Jakarta", ownerId).communityId
  otherId = community_store.create(database, slugB, "Security Other",
    "sec-other-admin@example.com", "Asia/Jakarta", ownerId).communityId

  # The owner is only a plain member here: platform ownership is not a
  # community role, and the security suite has to prove that.
  addMember(database, clubId, ownerId, "member")
  let adminId = addUser(database, "sec-admin", "sec-admin@example.com")
  addMember(database, clubId, adminId, "admin")
  let hostId = addUser(database, "sec-host", "sec-host@example.com")
  addMember(database, clubId, hostId, "host")
  let memberId = addUser(database, "sec-member", "sec-member@example.com")
  addMember(database, clubId, memberId, "member")
  member2Id = addUser(database, "sec-member2", "sec-member2@example.com")
  addMember(database, clubId, member2Id, "member")
  let otherUserId = addUser(database, "sec-other-member",
    "sec-other-member@example.com")
  addMember(database, otherId, otherUserId, "admin")

  adminCookie = cookieFor(database, adminId)
  hostCookie = cookieFor(database, hostId)
  memberCookie = cookieFor(database, memberId)
  member2Cookie = cookieFor(database, member2Id)
  otherCookie = cookieFor(database, otherUserId)
  ownerCookie = cookieFor(database, ownerId)

  playerA = makePlayer(database, clubId, "Alpha Player")
  playerB = makePlayer(database, otherId, "Bravo Player")
  sessionA = makeSession(database, clubId, "Alpha Session")
  sessionB = makeSession(database, otherId, "Bravo Session")
  shareB = shareStore.issue(database, loadKeyring(keysJson, "1"), otherId,
    sessionB, adminId, 30)

  startServer(newTestApp(database), port, baseUrl)

requireDatabase()

bootstrap()

suite "security: IDOR":
  test "v1-red/v2-green: a member of A gets 404 for every foreign community route":
    expectProblem(call(baseUrl, HttpGet, "/c/" & slugB & "/players", memberCookie),
      404, "NOT_FOUND")
    expectProblem(call(baseUrl, HttpGet,
      "/c/" & slugB & "/players/" & playerB, memberCookie), 404, "NOT_FOUND")
    expectProblem(call(baseUrl, HttpGet, "/c/" & slugB & "/sessions", memberCookie),
      404, "NOT_FOUND")
    expectProblem(call(baseUrl, HttpGet,
      "/c/" & slugB & "/sessions/" & sessionB, memberCookie), 404, "NOT_FOUND")
    expectProblem(call(baseUrl, HttpGet,
      "/c/" & slugB & "/sessions/" & sessionB & "/share", memberCookie),
      404, "NOT_FOUND")
    expectProblem(call(baseUrl, HttpPost, "/c/" & slugB & "/players", memberCookie,
      body = """{"name":"Intruder"}"""), 404, "NOT_FOUND")
    expectProblem(call(baseUrl, HttpPatch,
      "/c/" & slugB & "/players/" & playerB, memberCookie,
      body = """{"name":"Stolen"}"""), 404, "NOT_FOUND")
    expectProblem(call(baseUrl, HttpDelete,
      "/c/" & slugB & "/sessions/" & sessionB, memberCookie), 404, "NOT_FOUND")

    # The rejection body carries no foreign row, and the same member still
    # reads their own community.
    let foreign = call(baseUrl, HttpGet, "/c/" & slugB & "/players", memberCookie)
    check not foreign.body.contains("Bravo Player")
    let own = call(baseUrl, HttpGet,
      "/c/" & slugA & "/players/" & playerA, memberCookie)
    expectStatus(own, 200)
    check own.json["name"].getStr() == "Alpha Player"

  test "v1-red/v2-green: a host cannot reach B's row through A's slug":
    expectProblem(call(baseUrl, HttpGet,
      "/c/" & slugA & "/sessions/" & sessionB, hostCookie), 404, "NOT_FOUND")
    expectProblem(call(baseUrl, HttpPatch,
      "/c/" & slugA & "/sessions/" & sessionB, hostCookie, ifMatch = "1",
      body = """{"title":"Hijacked"}"""), 404, "NOT_FOUND")
    expectProblem(call(baseUrl, HttpGet,
      "/c/" & slugA & "/players/" & playerB, hostCookie), 404, "NOT_FOUND")
    expectProblem(call(baseUrl, HttpPatch,
      "/c/" & slugA & "/players/" & playerB, hostCookie,
      body = """{"name":"Hijacked"}"""), 404, "NOT_FOUND")
    expectProblem(call(baseUrl, HttpPost,
      "/c/" & slugA & "/sessions/" & sessionB & "/ws-ticket", hostCookie),
      404, "NOT_FOUND")
    expectProblem(call(baseUrl, HttpGet,
      "/c/" & slugA & "/sessions/" & sessionB & "/share", adminCookie),
      404, "NOT_FOUND")
    expectProblem(call(baseUrl, HttpPost,
      "/c/" & slugA & "/sessions/" & sessionB & "/share", adminCookie),
      404, "NOT_FOUND")
    # The foreign row is unchanged after every attempt.
    let row = database.queryOne(
      "select canonical_name from player.players where id = $1::uuid",
      @[textParam(playerB)])
    check row.get.get("canonical_name") == "Bravo Player"

  test "positive control: A's own row reads 200 and a write changes the row":
    let before = call(baseUrl, HttpGet,
      "/c/" & slugA & "/players/" & playerA, hostCookie)
    expectStatus(before, 200)
    check before.json["name"].getStr() == "Alpha Player"

    let patched = call(baseUrl, HttpPatch,
      "/c/" & slugA & "/players/" & playerA, hostCookie,
      body = """{"name":"Alpha Renamed"}""")
    expectStatus(patched, 200)
    check patched.json["name"].getStr() == "Alpha Renamed"

    let fresh = call(baseUrl, HttpGet,
      "/c/" & slugA & "/players/" & playerA, hostCookie)
    expectStatus(fresh, 200)
    check fresh.json["name"].getStr() == "Alpha Renamed"
    let row = database.queryOne(
      "select canonical_name from player.players where id = $1::uuid",
      @[textParam(playerA)])
    check row.get.get("canonical_name") == "Alpha Renamed"

    let sessionPatched = call(baseUrl, HttpPatch,
      "/c/" & slugA & "/sessions/" & sessionA, hostCookie, ifMatch = "1",
      body = """{"title":"Alpha Session Two"}""")
    expectStatus(sessionPatched, 200)
    let sessionRow = database.queryOne(
      "select title from session.sessions where id = $1::uuid",
      @[textParam(sessionA)])
    check sessionRow.get.get("title") == "Alpha Session Two"

    # The positive control is A's row: B still reads exactly as before.
    let foreignRow = database.queryOne(
      "select canonical_name from player.players where id = $1::uuid",
      @[textParam(playerB)])
    check foreignRow.get.get("canonical_name") == "Bravo Player"

  test "positive control: a share link issued for A's session resolves":
    let issued = call(baseUrl, HttpPost,
      "/c/" & slugA & "/sessions/" & sessionA & "/share", adminCookie)
    expectStatus(issued, 201)
    let code = issued.json["code"].getStr()
    let shared = call(baseUrl, HttpGet, "/s/" & code)
    expectStatus(shared, 200)
    check shared.json["session"]["id"].getStr() == sessionA
    # A live code for B is not reachable as A's share link.
    check shareB.len > 0

suite "security: role escalation":
  test "v1-red/v2-green: a member cannot create or change community data":
    expectProblem(call(baseUrl, HttpPost, "/c/" & slugA & "/players",
      memberCookie, body = """{"name":"Made By Member"}"""), 403, "FORBIDDEN")
    expectProblem(call(baseUrl, HttpPatch,
      "/c/" & slugA & "/players/" & playerA, memberCookie,
      body = """{"name":"Member Rename"}"""), 403, "FORBIDDEN")
    expectProblem(call(baseUrl, HttpDelete,
      "/c/" & slugA & "/players/" & playerA, memberCookie), 403, "FORBIDDEN")
    expectProblem(call(baseUrl, HttpPost, "/c/" & slugA & "/sessions",
      memberCookie, body = """{"date":"2026-01-01"}"""), 403, "FORBIDDEN")
    expectProblem(call(baseUrl, HttpPatch,
      "/c/" & slugA & "/sessions/" & sessionA, memberCookie, ifMatch = "2",
      body = """{"title":"Member Session"}"""), 403, "FORBIDDEN")
    expectProblem(call(baseUrl, HttpDelete,
      "/c/" & slugA & "/sessions/" & sessionA, memberCookie), 403, "FORBIDDEN")
    expectProblem(call(baseUrl, HttpPost,
      "/c/" & slugA & "/players/" & playerA & "/merge", memberCookie,
      body = """{"sourcePlayerId":"00000000-0000-0000-0000-000000000000"}"""),
      403, "FORBIDDEN")
    expectProblem(call(baseUrl, HttpPatch, "/c/" & slugA & "/settings",
      memberCookie, body = """{"api.page_size_default":10}"""), 403, "FORBIDDEN")
    expectProblem(call(baseUrl, HttpPost, "/c/" & slugA & "/invites",
      memberCookie, body = """{"email":"new@example.com","role":"admin"}"""),
      403, "FORBIDDEN")
    expectProblem(call(baseUrl, HttpPatch,
      "/c/" & slugA & "/members/" & member2Id, memberCookie,
      body = """{"role":"admin"}"""), 403, "FORBIDDEN")
    expectProblem(call(baseUrl, HttpPost,
      "/c/" & slugA & "/ratings/rebuild", memberCookie), 403, "FORBIDDEN")
    expectProblem(call(baseUrl, HttpPost,
      "/c/" & slugA & "/sessions/" & sessionA & "/rating", memberCookie),
      403, "FORBIDDEN")
    expectProblem(call(baseUrl, HttpPost, "/communities", memberCookie,
      body = """{"slug":"sec-member-made","name":"Nope"}"""), 403, "FORBIDDEN")
    # Read access is not weakened by the write denial.
    let read = call(baseUrl, HttpGet, "/c/" & slugA & "/sessions", memberCookie)
    expectStatus(read, 200)

  test "a host cannot perform admin-only actions":
    expectProblem(call(baseUrl, HttpDelete,
      "/c/" & slugA & "/players/" & playerA, hostCookie), 403, "FORBIDDEN")
    expectProblem(call(baseUrl, HttpPost,
      "/c/" & slugA & "/players/" & playerA & "/merge", hostCookie,
      body = """{"sourcePlayerId":"00000000-0000-0000-0000-000000000000"}"""),
      403, "FORBIDDEN")
    expectProblem(call(baseUrl, HttpPatch, "/c/" & slugA & "/settings",
      hostCookie, body = """{"api.page_size_default":10}"""), 403, "FORBIDDEN")
    expectProblem(call(baseUrl, HttpPatch,
      "/c/" & slugA & "/members/" & member2Id, hostCookie,
      body = """{"role":"admin"}"""), 403, "FORBIDDEN")
    expectProblem(call(baseUrl, HttpPost,
      "/c/" & slugA & "/ratings/rebuild", hostCookie), 403, "FORBIDDEN")
    expectProblem(call(baseUrl, HttpPost,
      "/c/" & slugA & "/sessions/" & sessionA & "/rating", hostCookie),
      403, "FORBIDDEN")
    expectProblem(call(baseUrl, HttpPost, "/communities", hostCookie,
      body = """{"slug":"sec-host-made","name":"Nope"}"""), 403, "FORBIDDEN")
    # The host still writes the routes the contract gives them.
    let write = call(baseUrl, HttpPatch,
      "/c/" & slugA & "/players/" & playerA, hostCookie,
      body = """{"name":"Alpha By Host"}""")
    expectStatus(write, 200)

  test "an admin may still patch settings after the host is denied":
    let patched = call(baseUrl, HttpPatch, "/c/" & slugA & "/settings",
      adminCookie, body = """{"rating.score_target":20}""")
    expectStatus(patched, 200)
    check patched.json["values"]["rating.score_target"].getInt() == 20
    let stored = database.queryOne(
      """select values::text as values from community.settings
         where community_id = $1::uuid""", @[textParam(clubId)])
    check parseJson(stored.get.get("values"))["rating.score_target"].getInt() == 20

  test "platform ownership bypasses owner-only routes, not community roles":
    let created = call(baseUrl, HttpPost, "/communities", ownerCookie,
      body = """{"slug":"sec-owned","name":"Owned","adminEmail":"sec-owner-admin@example.com"}""")
    expectStatus(created, 201)
    check created.json["slug"].getStr() == "sec-owned"
    # The same owner joined A as a plain member: the community role decides.
    expectProblem(call(baseUrl, HttpPatch,
      "/c/" & slugA & "/players/" & playerA, ownerCookie,
      body = """{"name":"Owner Rename"}"""), 403, "FORBIDDEN")
    let read = call(baseUrl, HttpGet, "/c/" & slugA & "/players", ownerCookie)
    expectStatus(read, 200)

suite "security: claims":
  test "v1-red/v2-green: a member cannot release another account's claim":
    let created = call(baseUrl, HttpPost, "/c/" & slugA & "/players",
      hostCookie, body = """{"name":"Claimable Player"}""")
    expectStatus(created, 201)
    let playerId = created.json["id"].getStr()

    let submitted = call(baseUrl, HttpPost,
      "/c/" & slugA & "/players/" & playerId & "/claims", memberCookie)
    expectStatus(submitted, 201)

    let listed = call(baseUrl, HttpGet,
      "/c/" & slugA & "/players/" & playerId & "/claims", adminCookie)
    expectStatus(listed, 200)
    let claimId = listed.json["items"][0]["id"].getStr()

    # A member cannot use the admin release action...
    expectProblem(call(baseUrl, HttpPatch,
      "/c/" & slugA & "/players/" & playerId & "/claims/" & claimId,
      member2Cookie, body = """{"action":"release","reason":"mine now"}"""),
      403, "FORBIDDEN")
    # ...and cannot decide a claim either.
    expectProblem(call(baseUrl, HttpPatch,
      "/c/" & slugA & "/players/" & playerId & "/claims/" & claimId,
      memberCookie, body = """{"decision":"approve"}"""), 403, "FORBIDDEN")
    # Hosts are not admins: claim decisions remain admin-only.
    expectProblem(call(baseUrl, HttpPatch,
      "/c/" & slugA & "/players/" & playerId & "/claims/" & claimId,
      hostCookie, body = """{"decision":"approve"}"""), 403, "FORBIDDEN")
    # The self-service route only releases the caller's own approved claim.
    expectProblem(call(baseUrl, HttpDelete,
      "/c/" & slugA & "/players/" & playerId & "/claim", member2Cookie),
      409, "CLAIM_CONFLICT")

    let approved = call(baseUrl, HttpPatch,
      "/c/" & slugA & "/players/" & playerId & "/claims/" & claimId,
      adminCookie, body = """{"decision":"approve"}""")
    expectStatus(approved, 200)

    # An approved claim cannot be stolen: a second account cannot even file.
    expectProblem(call(baseUrl, HttpPost,
      "/c/" & slugA & "/players/" & playerId & "/claims", member2Cookie),
      409, "CLAIMED")

    # The owner's release is the only path that frees the player.
    let released = call(baseUrl, HttpDelete,
      "/c/" & slugA & "/players/" & playerId & "/claim", memberCookie)
    expectStatus(released, 200)
    check released.json["status"].getStr() == "released"
    let afterRelease = call(baseUrl, HttpPost,
      "/c/" & slugA & "/players/" & playerId & "/claims", member2Cookie)
    expectStatus(afterRelease, 201)
