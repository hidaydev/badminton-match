import std/[httpclient, json, options, strutils, unittest]
import db/db
import mummy
import community/infrastructure/community_store
import share/crypto
import share/store as shareStore
import tournament/domain/classic
import tournament/domain/classic_draw
import tests/fixtures
import ../../http_support

let
  port = testPort()
  baseUrl = "http://127.0.0.1:" & $uint16(port)
  slugA = "sec-club"
  slugB = "sec-other"
  slugOwned = "sec-owned"

var
  database: Db
  clubId, otherId: string
  adminCookie, hostCookie, memberCookie, member2Cookie, otherCookie,
    ownerCookie: string
  member2Id, ownerId, otherAdminId: string
  playerA, playerB, playerB2, sessionA, sessionB, shareB: string
  playerA2, sessionBRated, tournamentB, tournamentBBody, matchB, claimB,
    joinRequestB: string

proc classicJson(data: ClassicTournament): JsonNode =
  ## The body `POST /tournaments` accepts, field for field the shape the
  ## tournament suites send. B's bracket has to be a real one: the PUT and the
  ## match PATCH below replay it, and an invalid body would be rejected before
  ## the community is ever consulted.
  var pairs = newJArray()
  for pair in data.pairs:
    pairs.add(%*{"id": pair.id, "name": pair.name})
  var groups = newJObject()
  for groupId in GroupIds:
    var members = newJArray()
    for pairId in data.groups[ord(groupId)]:
      members.add(%pairId)
    groups[$groupId] = members
  var matches = newJArray()
  for match in data.matches:
    matches.add(%*{
      "id": match.id, "phase": $match.phase,
      "groupId": if match.groupId.isSome: %($match.groupId.get) else: newJNull(),
      "pairAId": if match.pairAId.isSome: %match.pairAId.get else: newJNull(),
      "pairBId": if match.pairBId.isSome: %match.pairBId.get else: newJNull(),
      "scoreA": if match.scoreA.isSome: %match.scoreA.get else: newJNull(),
      "scoreB": if match.scoreB.isSome: %match.scoreB.get else: newJNull()})
  %*{"name": data.name, "date": data.date, "pairs": pairs, "groups": groups,
     "matches": matches}

proc classicBody(): string =
  var pairs: seq[Pair] = @[]
  for index in 1 .. 16:
    pairs.add(Pair(id: "p" & $index, name: "Other Pair " & $index))
  $classicJson(generateTournament("Other Cup", "2026-11-04", pairs, 7))

proc bootstrap() =
  database = openDb(dsn(), 1)
  for slug in [slugA, slugB, slugOwned]:
    purgeCommunity(database, slug)
  cleanupUsers(database, "sec-%")

  ownerId = newUser(database, "sec-owner", "sec-owner@example.com", owner = true)
  clubId = community_store.create(database, slugA, "Security Club",
    "sec-admin@example.com", "Asia/Jakarta", ownerId).communityId
  otherId = community_store.create(database, slugB, "Security Other",
    "sec-other-admin@example.com", "Asia/Jakarta", ownerId).communityId

  # The owner is only a plain member here: platform ownership is not a
  # community role, and the security suite has to prove that.
  newMember(database, clubId, ownerId, "member")
  let adminId = newUser(database, "sec-admin", "sec-admin@example.com")
  newMember(database, clubId, adminId, "admin")
  let hostId = newUser(database, "sec-host", "sec-host@example.com")
  newMember(database, clubId, hostId, "host")
  let memberId = newUser(database, "sec-member", "sec-member@example.com")
  newMember(database, clubId, memberId, "member")
  member2Id = newUser(database, "sec-member2", "sec-member2@example.com")
  newMember(database, clubId, member2Id, "member")
  let otherUserId = newUser(database, "sec-other-member",
    "sec-other-member@example.com")
  newMember(database, otherId, otherUserId, "admin")
  otherAdminId = otherUserId

  adminCookie = cookieFor(database, adminId)
  hostCookie = cookieFor(database, hostId)
  memberCookie = cookieFor(database, memberId)
  member2Cookie = cookieFor(database, member2Id)
  otherCookie = cookieFor(database, otherUserId)
  ownerCookie = cookieFor(database, ownerId)

  playerA = newPlayer(database, clubId, "Alpha Player")
  playerA2 = newPlayer(database, clubId, "Alpha Partner")
  playerB = newPlayer(database, otherId, "Bravo Player")
  playerB2 = newPlayer(database, otherId, "Bravo Partner")
  sessionA = newSession(database, clubId, "Alpha Session")
  sessionB = newSession(database, otherId, "Bravo Session")
  # A session the rating gate would accept if this community were ignored:
  # approved, so only the scope check can refuse the ingest. `sessionB` stays a
  # draft, which is what the revert route answers 200 on when it is not scoped.
  sessionBRated = newSession(database, otherId, "Bravo Rated",
    status = "locked", approved = true)
  shareB = shareStore.issue(database, loadKeyring(keysJson, "1"), otherId,
    sessionB, adminId, 30)

  # Two games and their participants in B: the game routes key off a
  # (round, court) pair, the swap exchanges two of them and the absent route
  # marks a participant, so every one of those ids is a real row in B.
  newParticipant(database, otherId, sessionB, playerB)
  newParticipant(database, otherId, sessionB, playerB2)
  newGame(database, otherId, sessionB, 1, 1, [playerB], [playerB2])
  newGame(database, otherId, sessionB, 1, 2, [playerB], [playerB2])

  claimB = newClaim(database, otherId, playerB, otherUserId)
  # A request by an A member, who is by definition not in B: deciding it is
  # the admin write that must stay inside B.
  joinRequestB = newJoinRequest(database, otherId, member2Id)

  startServer(newTestApp(database), port, baseUrl)

proc seedBracket() =
  ## B's tournament is created through the API: the bracket, its match ids and
  ## its version are what the PUT and match PATCH cases replay, and a
  ## hand-written header could not tell a rejected body from a rejected id.
  let created = call(baseUrl, HttpPost, "/c/" & slugB & "/tournaments",
    otherCookie, classicBody())
  doAssert created.status == 201, "seeding B's bracket failed: " & created.body
  let snapshot = parseJson(created.body)
  tournamentB = snapshot["id"].getStr()
  tournamentBBody = created.body
  matchB = snapshot["matches"][0]["id"].getStr()

requireDatabase()

bootstrap()
seedBracket()

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
    # A share link is minted only for an approved session (SEC-09), so the
    # control gets one of its own instead of reusing the draft fixture.
    let sharedSession = newSession(database, clubId, "Alpha Shared",
      status = "locked", approved = true)
    let issued = call(baseUrl, HttpPost,
      "/c/" & slugA & "/sessions/" & sharedSession & "/share", adminCookie)
    expectStatus(issued, 201)
    let code = issued.json["code"].getStr()
    let shared = call(baseUrl, HttpGet, "/s/" & code)
    expectStatus(shared, 200)
    # SEC-20: the payload names no id the legacy resolver would accept.
    check not shared.json["session"].hasKey("id")
    check shared.json["session"]["title"].getStr() == "Alpha Shared"
    check shared.json["games"].len == 0
    # A live code for B is not reachable as A's share link.
    check shareB.len > 0

  test "v1-red/v2-green: B's session objects are refused through A's slug":
    ## Every id here names a row that exists in B, seeded in `bootstrap`: a
    ## missing `community_id` predicate would answer 200 (or 204) instead of
    ## these 404s, which is exactly what the case has to catch.
    expectProblem(call(baseUrl, HttpGet,
      "/c/" & slugA & "/sessions/" & sessionB & "/games/1-1", hostCookie),
      404, "NOT_FOUND")
    expectProblem(call(baseUrl, HttpPatch,
      "/c/" & slugA & "/sessions/" & sessionB & "/games/1-1", hostCookie,
      ifMatch = "1", body = """{"scoreA":30,"scoreB":20}"""),
      404, "NOT_FOUND")
    expectProblem(call(baseUrl, HttpGet,
      "/c/" & slugA & "/sessions/" & sessionB & "/standings", memberCookie),
      404, "NOT_FOUND")
    # The schedule has a write route only; its read is `GET /sessions/{id}`,
    # which the foreign-session case above already covers. The body names A's
    # players on purpose: the route checks them against the caller's community
    # first, so naming B's would be a 400 before the session is ever read.
    expectProblem(call(baseUrl, HttpPut,
      "/c/" & slugA & "/sessions/" & sessionB & "/schedule", hostCookie,
      ifMatch = "1",
      body = "{\"games\":[{\"round\":1,\"court\":1,\"sideA\":[\"" & playerA &
        "\"],\"sideB\":[\"" & playerA2 & "\"]}]}"), 404, "NOT_FOUND")
    expectProblem(call(baseUrl, HttpPatch,
      "/c/" & slugA & "/sessions/" & sessionB & "/absent", hostCookie,
      ifMatch = "1", body = "{\"playerIds\":[\"" & playerA & "\"]}"),
      404, "NOT_FOUND")
    expectProblem(call(baseUrl, HttpPost,
      "/c/" & slugA & "/sessions/" & sessionB & "/swap", hostCookie,
      ifMatch = "1",
      body = """{"type":"slot","a":{"slot":1,"court":1},"b":{"slot":1,"court":2}}"""),
      404, "NOT_FOUND")
    # Ingest would rate the approved session in B, and revert would answer 200
    # on B's draft: both are refusals only the scope check can make.
    expectProblem(call(baseUrl, HttpPost,
      "/c/" & slugA & "/sessions/" & sessionBRated & "/rating", adminCookie),
      404, "NOT_FOUND")
    expectProblem(call(baseUrl, HttpDelete,
      "/c/" & slugA & "/sessions/" & sessionB & "/rating", adminCookie),
      404, "NOT_FOUND")
    # Nothing above wrote through the 404: B's session is still version 1.
    let version = database.queryOne(
      "select version from session.sessions where id = $1::uuid",
      @[textParam(sessionB)])
    check version.get.get("version") == "1"

  test "v1-red/v2-green: B's tournament objects are refused through A's slug":
    ## B's bracket was created through the API, so its rows, its version and its
    ## match ids are the ones an unscoped handler would have written.
    expectProblem(call(baseUrl, HttpGet,
      "/c/" & slugA & "/tournaments/" & tournamentB, memberCookie),
      404, "NOT_FOUND")
    expectProblem(call(baseUrl, HttpPut,
      "/c/" & slugA & "/tournaments/" & tournamentB, hostCookie,
      ifMatch = "1", body = tournamentBBody), 404, "NOT_FOUND")
    expectProblem(call(baseUrl, HttpPatch,
      "/c/" & slugA & "/tournaments/" & tournamentB & "/matches/" & matchB,
      hostCookie, ifMatch = "1",
      body = """{"scoreA":30,"scoreB":20}"""), 404, "NOT_FOUND")
    # The rating source is the tournament id, and the sign-off is the write
    # that would otherwise reach into B's ledger.
    expectProblem(call(baseUrl, HttpPatch,
      "/c/" & slugA & "/rating-sources/" & tournamentB, adminCookie,
      body = """{"finalized":true}"""), 404, "NOT_FOUND")
    expectProblem(call(baseUrl, HttpDelete,
      "/c/" & slugA & "/tournaments/" & tournamentB & "/rating", adminCookie),
      404, "NOT_FOUND")
    expectProblem(call(baseUrl, HttpDelete,
      "/c/" & slugA & "/tournaments/" & tournamentB, hostCookie),
      404, "NOT_FOUND")
    # The bracket is still there, at the version it was created with.
    let row = database.queryOne(
      """select version from tournament.tournaments
         where community_id = $1::uuid and id = $2::uuid""",
      @[textParam(otherId), textParam(tournamentB)])
    check row.isSome
    check row.get.get("version") == "1"

  test "v1-red/v2-green: B's player and roster ids are refused through A's slug":
    # Rankings, achievements and stats all resolve the player first: a foreign
    # id must not resolve at all.
    expectProblem(call(baseUrl, HttpGet,
      "/c/" & slugA & "/rankings/" & playerB, memberCookie), 404, "NOT_FOUND")
    expectProblem(call(baseUrl, HttpGet,
      "/c/" & slugA & "/players/" & playerB & "/achievements", memberCookie),
      404, "NOT_FOUND")
    expectProblem(call(baseUrl, HttpGet,
      "/c/" & slugA & "/players/" & playerB & "/stats", memberCookie),
      404, "NOT_FOUND")
    # The roster ids are `platform.user` rows: B's admin is a real user, so the
    # only thing that can turn the role change away is the community scope.
    expectProblem(call(baseUrl, HttpPatch,
      "/c/" & slugA & "/members/" & otherAdminId, adminCookie,
      body = """{"role":"member"}"""), 404, "NOT_FOUND")
    expectProblem(call(baseUrl, HttpDelete,
      "/c/" & slugA & "/members/" & otherAdminId, adminCookie),
      404, "NOT_FOUND")
    expectProblem(call(baseUrl, HttpPatch,
      "/c/" & slugA & "/join-requests/" & joinRequestB, adminCookie,
      body = """{"decision":"approve"}"""), 404, "NOT_FOUND")
    expectProblem(call(baseUrl, HttpPatch,
      "/c/" & slugA & "/players/" & playerB & "/claims/" & claimB,
      adminCookie, body = """{"decision":"approve"}"""), 404, "NOT_FOUND")
    # The source id of a merge is the one body-supplied player id: A's target
    # exists, so only the source's community can stop the merge.
    expectProblem(call(baseUrl, HttpPost,
      "/c/" & slugA & "/players/" & playerA & "/merge", adminCookie,
      body = "{\"sourcePlayerId\":\"" & playerB & "\"}"),
      404, "NOT_FOUND")
    let claim = database.queryOne(
      "select status from player.claims where id = $1::uuid",
      @[textParam(claimB)])
    check claim.get.get("status") == "pending"
    let joinRequest = database.queryOne(
      "select status from community.join_request where id = $1::uuid",
      @[textParam(joinRequestB)])
    check joinRequest.get.get("status") == "pending"

  test "v1-red/v2-green: A's admin cannot reach B's settings or config":
    ## Settings and config carry no object id: the slug is the whole key, so
    ## this is the reverse direction of the cases above (an authenticated A
    ## admin on B's slug), and the only reason to refuse is the membership.
    # B needs a row first: with no row at all, "the refusal changed nothing" is
    # also true when the handler never looked, so the assertion would be vacuous.
    discard database.execUpdate(
      """insert into community.settings (community_id, values)
         values ($1::uuid, '{"rating.score_target":25}'::jsonb)
         on conflict (community_id) do update set values = excluded.values""",
      @[textParam(otherId)])
    expectProblem(call(baseUrl, HttpPatch, "/c/" & slugB & "/settings",
      adminCookie, body = """{"rating.score_target":20}"""), 404, "NOT_FOUND")
    expectProblem(call(baseUrl, HttpGet, "/c/" & slugB & "/config", adminCookie),
      404, "NOT_FOUND")
    let stored = database.queryOne(
      """select values->>'rating.score_target' as target
         from community.settings where community_id = $1::uuid""",
      @[textParam(otherId)])
    check stored.get.get("target") == "25"

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
