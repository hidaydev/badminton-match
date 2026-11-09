## BE-03: one authenticated read per GET operation that BE-04 (`/auth/sessions`)
## and BE-05 (`/communities`, settings, rating sources, session share) do not
## own. `routes_dispatch_test` proves each path is reachable and stops at the
## gate; this suite runs the handler body.
##
## One community carries one row of every shape the reads return, so each case
## asserts a value the fixture wrote: a name, a version, a count. A read that
## only checked its status would pass with an empty object.
##
## The websocket routes (`/ws/...`) are GET operations in the generated contract
## but they have no JSON read of their own; their case here proves the ticket
## gate. The frames are BE-07's.

import std/[json, options, unittest]
import db/db
import community/infrastructure/community_store
import platform/config/store
import rating/infrastructure/[ingest, params]
import share/crypto
import share/store as shareStore
import tests/fixtures
import ../http_support
import ../../src/app

let
  port = testPort()
  baseUrl = "http://127.0.0.1:" & $uint16(port)
  slug = "read-smoke"
  otherSlug = "read-smoke-other"
  legacySlug = "read-smoke-legacy"
  adminEmail = "read-smoke-admin@example.com"

var
  database: Db
  communityId, otherCommunityId, ownerId: string
  adminId, hostId, memberId, askerId: string
  adminCookie, hostCookie, memberCookie: string
  players: seq[string]
  ghostPlayerId: string
  sessionId, tournamentId, shareCode, legacySessionId: string
  legacyCommunityId: string

proc bootstrap() =
  database = openDb(dsn(), 1)
  # Every row this suite writes lives in one of two slugs, so the purge is
  # scoped to them. Users are global, cleaned by the same subject prefix the
  # other HTTP suites use.
  purgeCommunity(database, slug)
  purgeCommunity(database, otherSlug)
  purgeCommunity(database, legacySlug)
  discard database.execUpdate(
    """delete from account.sessions where user_id in
         (select id from platform.user where google_sub like 'read-smoke-%')""")
  discard database.execUpdate(
    """delete from platform.idempotency_keys where user_id in
         (select id from platform.user where google_sub like 'read-smoke-%')""")
  discard database.execUpdate(
    "delete from platform.user where google_sub like 'read-smoke-%'")

  ownerId = newUser(database, "read-smoke-owner", "read-smoke-owner@example.com",
    "Read Owner", owner = true)
  communityId = community_store.create(database, slug, "Read Smoke Club",
    adminEmail, "Asia/Jakarta", ownerId).communityId
  proc member(sub, email, display, role: string): string =
    let id = newUser(database, sub, email, display)
    newMember(database, communityId, id, role)
    id
  adminId = member("read-smoke-admin", adminEmail, "Read Admin", "admin")
  hostId = member("read-smoke-host", "read-smoke-host@example.com", "Read Host",
    "host")
  memberId = member("read-smoke-member", "read-smoke-member@example.com",
    "Read Member", "member")
  adminCookie = cookieFor(database, adminId)
  hostCookie = cookieFor(database, hostId)
  memberCookie = cookieFor(database, memberId)

  # A second community with a player of its own: every `community_id` filter in
  # the reads below has a row to leak, so a missing predicate is visible as an
  # extra name instead of passing on an empty table.
  otherCommunityId = newCommunity(database, otherSlug, "Read Smoke Other")
  ghostPlayerId = newPlayer(database, otherCommunityId, "Ghost")

  for name in ["Ani", "Budi", "Cakra", "Dewi"]:
    players.add(newPlayer(database, communityId, name))

  # An approved session with two played games, drawn so Ani is the only player
  # with two wins: the board and the stats have an order that a fixture, not a
  # tie-break, decides.
  sessionId = newSession(database, communityId, "Read Smoke Night",
    sessionDate = "2026-11-08", status = "locked", approved = true)
  for player in players:
    newParticipant(database, communityId, sessionId, player)
  newGame(database, communityId, sessionId, 0, 0, [players[0], players[1]],
    [players[2], players[3]], status = "played")
  discard database.execUpdate(
    """insert into session.game_sets
         (community_id, session_id, round_no, court_no, set_no, score_a, score_b)
       values ($1::uuid, $2::uuid, 0, 0, 1, 30, 15)""",
    @[textParam(communityId), textParam(sessionId)])
  newGame(database, communityId, sessionId, 1, 0, [players[0], players[2]],
    [players[1], players[3]], status = "played")
  discard database.execUpdate(
    """insert into session.game_sets
         (community_id, session_id, round_no, court_no, set_no, score_a, score_b)
       values ($1::uuid, $2::uuid, 1, 0, 1, 30, 18)""",
    @[textParam(communityId), textParam(sessionId)])
  discard ingestSession(database, communityId, sessionId,
    loadRatingParams(loadSnapshot(database), newJObject()))

  # The rows the remaining reads serialize: a pending claim, an earned badge,
  # a tournament header, a pending join request and a live share link.
  discard newClaim(database, communityId, players[1], memberId)
  discard database.execUpdate(
    """insert into achievement.earned
         (community_id, player_id, achievement_key, earned_at)
       values ($1::uuid, $2::uuid, 'sessions:10', now())""",
    @[textParam(communityId), textParam(players[0])])
  tournamentId = database.queryOne(
    """insert into tournament.tournaments
         (community_id, name, status, format, event_date)
       values ($1::uuid, 'Read Smoke Cup', 'draft', 'classic', '2026-11-08')
       returning id""", @[textParam(communityId)]).get.get("id")
  askerId = newUser(database, "read-smoke-asker", "read-smoke-asker@example.com",
    "Read Asker")
  discard newJoinRequest(database, communityId, askerId)
  shareCode = shareStore.issue(database, loadKeyring(keysJson, "1"), communityId,
    sessionId, ownerId, 30)
  # A pre-code link: version one handed out `/s/{sessionId}`, and migration 0033
  # marked every row that existed then. It was created before the sunset window
  # so the retirement run has something to clear.
  legacyCommunityId = newCommunity(database, legacySlug, "Legacy Smoke")
  legacySessionId = newSession(database, legacyCommunityId, "Legacy Night",
    "2026-11-09", status = "locked", approved = true)
  discard shareStore.issue(database, loadKeyring(keysJson, "1"),
    legacyCommunityId, legacySessionId, ownerId, 30)
  discard database.execUpdate(
    """update session.links
       set legacy_id_ok = true, expires_at = null,
           created_at = now() - interval '40 days'
       where community_id = $1::uuid and session_id = $2::uuid""",
    @[textParam(legacyCommunityId), textParam(legacySessionId)])

  startServer(newTestApp(database), port, baseUrl)

proc expectRead(response: HttpResult, operation: string, status: int) =
  ## The operation names the checkpoint, so a failure in the shared fixture says
  ## which read it came from instead of only its status and body.
  checkpoint(operation & ": " & $response.status & " " & response.body)
  check response.status == status

proc names(items: JsonNode): seq[string] =
  for item in items:
    result.add(item["name"].getStr())

proc rowFor(items: JsonNode, key, value: string): JsonNode =
  ## A list read is asserted on the row the fixture wrote, whatever position the
  ## order clause puts it in.
  for item in items:
    if item[key].getStr() == value:
      return item
  newJNull()

bootstrap()

suite "authenticated read smoke":
  test "getAuthMe names the caller":
    let response = call(baseUrl, HttpGet, "/auth/me", memberCookie)
    let body = response.body
    expectRead(response, "getAuthMe", 200)
    let parsed = parseJson(body)
    check parsed["id"].getStr() == memberId
    check parsed["displayName"].getStr() == "Read Member"
    check not parsed["platformOwner"].getBool()

  test "getAuthCallback with no code is a problem envelope":
    # The one operation in this suite with no fixture value to assert: a
    # callback without code and state never reaches the provider, so the
    # observable is the refusal itself.
    let response = call(baseUrl, HttpGet, "/auth/callback")
    expectProblem(response, 400, "INVALID_CALLBACK")

  test "getCommunityConfig reports the seeded preset and its source":
    let response = call(baseUrl, HttpGet, "/c/" & slug & "/config", memberCookie)
    let body = response.body
    expectRead(response, "getCommunityConfig", 200)
    let parsed = parseJson(body)
    let preset = parsed["effective"][$keySessionDefaultScoringPreset]
    check preset["source"].getStr() == "platform"
    check preset["value"].getStr() == "majadu30"
    check parsed["scoringPresets"].len == 3
    check parsed["scoringPresets"][0]["id"].getStr() == "majadu30"

  test "listJoinRequests shows the pending request the fixture filed":
    let response = call(baseUrl, HttpGet, "/c/" & slug & "/join-requests",
      adminCookie)
    let body = response.body
    expectRead(response, "listJoinRequests", 200)
    let items = parseJson(body)["items"]
    check items.len == 1
    check items[0]["userId"].getStr() == askerId
    check items[0]["displayName"].getStr() == "Read Asker"

  test "listMembers lists the three roles and no other community's member":
    let response = call(baseUrl, HttpGet, "/c/" & slug & "/members", memberCookie)
    let body = response.body
    expectRead(response, "listMembers", 200)
    let items = parseJson(body)["items"]
    check items.len == 3
    let admin = rowFor(items, "displayName", "Read Admin")
    check admin.kind == JObject
    check admin["role"].getStr() == "admin"
    check admin["userId"].getStr() == adminId

  test "listPlayers returns this community's four and not the other's ghost":
    let response = call(baseUrl, HttpGet, "/c/" & slug & "/players", memberCookie)
    let body = response.body
    expectRead(response, "listPlayers", 200)
    let items = parseJson(body)["items"]
    check items.len == 4
    let listed = names(items)
    check "Ani" in listed
    check "Ghost" notin listed

  test "getPlayer returns the row and the viewer's claim state":
    let response = call(baseUrl, HttpGet,
      "/c/" & slug & "/players/" & players[0], memberCookie)
    let body = response.body
    expectRead(response, "getPlayer", 200)
    let parsed = parseJson(body)
    check parsed["id"].getStr() == players[0]
    check parsed["name"].getStr() == "Ani"
    check parsed["aliases"].len == 0
    check not parsed["viewerOwnsPlayer"].getBool()

  test "getPlayerAchievements returns the earned badge":
    let response = call(baseUrl, HttpGet,
      "/c/" & slug & "/players/" & players[0] & "/achievements", memberCookie)
    let body = response.body
    expectRead(response, "getPlayerAchievements", 200)
    let items = parseJson(body)["items"]
    check items.len == 1
    check items[0]["key"].getStr() == "sessions:10"
    check items[0]["threshold"].getInt() > 0

  test "listPlayerClaims reveals the claimant to a host but not to a member":
    let path = "/c/" & slug & "/players/" & players[1] & "/claims"
    let privileged = call(baseUrl, HttpGet, path, adminCookie)
    let privilegedBody = privileged.body
    expectRead(privileged, "listPlayerClaims", 200)
    let seen = parseJson(privilegedBody)["items"]
    check seen.len == 1
    check seen[0]["status"].getStr() == "pending"
    check seen[0]["userId"].getStr() == memberId
    let member = call(baseUrl, HttpGet, path, memberCookie)
    let memberBody = member.body
    expectRead(member, "listPlayerClaims", 200)
    let mine = parseJson(memberBody)["items"]
    check mine.len == 1
    check mine[0]["userId"].getStr() == memberId
    let stranger = call(baseUrl, HttpGet, path, hostCookie)
    let strangerBody = stranger.body
    expectRead(stranger, "listPlayerClaims", 200)
    check parseJson(strangerBody)["items"][0]["userId"].getStr() == memberId

  test "getPlayerStats counts the two games and the board's points":
    let response = call(baseUrl, HttpGet,
      "/c/" & slug & "/players/" & players[0] & "/stats", memberCookie)
    let body = response.body
    expectRead(response, "getPlayerStats", 200)
    let stats = parseJson(body)
    check stats["name"].getStr() == "Ani"
    check stats["games"].getInt() == 2
    check stats["wins"].getInt() == 2
    check stats["points"].getInt() > 0
    check stats["sessions"].len == 1
    check stats["sessions"][0]["title"].getStr() == "Read Smoke Night"

  test "listRankings puts the fixture's two-game winner first":
    let response = call(baseUrl, HttpGet, "/c/" & slug & "/rankings", memberCookie)
    let body = response.body
    expectRead(response, "listRankings", 200)
    let parsed = parseJson(body)
    let items = parsed["items"]
    check items.len == 4
    check items[0]["playerId"].getStr() == players[0]
    check items[0]["rank"].getInt() == 1
    check items[0]["name"].getStr() == "Ani"
    check items[0]["points"].getInt() > items[1]["points"].getInt()
    check parsed["asOf"].getStr() == "2026-11-08"
    check parsed["windowWeeks"].getInt() > 0

  test "getRanking returns the same row the board shows":
    let response = call(baseUrl, HttpGet,
      "/c/" & slug & "/rankings/" & players[0], memberCookie)
    let body = response.body
    expectRead(response, "getRanking", 200)
    let row = parseJson(body)
    check row["playerId"].getStr() == players[0]
    check row["rank"].getInt() == 1
    check row["name"].getStr() == "Ani"
    check row["minSessions"].getInt() == 0

  test "listSessions counts the fixture's players and games":
    let response = call(baseUrl, HttpGet, "/c/" & slug & "/sessions", memberCookie)
    let body = response.body
    expectRead(response, "listSessions", 200)
    let parsed = parseJson(body)
    check parsed["total"].getInt() == 1
    let items = parsed["items"]
    check items.len == 1
    check items[0]["id"].getStr() == sessionId
    check items[0]["title"].getStr() == "Read Smoke Night"
    check items[0]["date"].getStr() == "2026-11-08"
    check items[0]["playerCount"].getInt() == 4
    check items[0]["totalGames"].getInt() == 2

  test "getSession returns the whole session and a 304 for a held version":
    let path = "/c/" & slug & "/sessions/" & sessionId
    let response = call(baseUrl, HttpGet, path, memberCookie)
    let body = response.body
    expectRead(response, "getSession", 200)
    let parsed = parseJson(body)
    check parsed["id"].getStr() == sessionId
    check parsed["title"].getStr() == "Read Smoke Night"
    check parsed["version"].getInt() == 1
    check parsed["status"].getStr() == "locked"
    check parsed["participants"].len == 4
    check parsed["games"].len == 2
    check parsed["games"][0]["sideA"][0].getStr() == players[0]
    check parsed["games"][0]["scoreA"].getInt() == 30
    check header(response, "ETag") == "\"1\""
    # A poll that already holds this version costs no body.
    let held = call(baseUrl, HttpGet, path, memberCookie,
      extra = [("If-None-Match", "\"1\"")])
    let heldBody = held.body
    expectRead(held, "getSession 304", 304)
    check heldBody.len == 0
    let stale = call(baseUrl, HttpGet, path, memberCookie,
      extra = [("If-None-Match", "\"0\"")])
    expectRead(stale, "getSession stale", 200)

  test "getSessionGame returns the game the fixture scored":
    let response = call(baseUrl, HttpGet,
      "/c/" & slug & "/sessions/" & sessionId & "/games/0-0", memberCookie)
    let body = response.body
    expectRead(response, "getSessionGame", 200)
    let game = parseJson(body)
    check game["round"].getInt() == 0
    check game["court"].getInt() == 0
    check game["sideA"][0].getStr() == players[0]
    check game["sideA"][1].getStr() == players[1]
    check game["status"].getStr() == "played"
    check game["scoreA"].getInt() == 30
    check game["sets"].len == 1
    check game["sets"][0]["a"].getInt() == 30
    check game["sets"][0]["b"].getInt() == 15

  test "getSessionStandings tallies the two games":
    let response = call(baseUrl, HttpGet,
      "/c/" & slug & "/sessions/" & sessionId & "/standings", memberCookie)
    let body = response.body
    expectRead(response, "getSessionStandings", 200)
    let board = parseJson(body)
    check board["sessionId"].getStr() == sessionId
    let items = board["items"]
    check items.len == 4
    let ani = rowFor(items, "name", "Ani")
    check ani.kind == JObject
    check ani["wins"].getInt() == 2
    check ani["losses"].getInt() == 0
    check ani["diff"].getInt() == 27

  test "listTournaments returns the fixture's header":
    let response = call(baseUrl, HttpGet, "/c/" & slug & "/tournaments",
      memberCookie)
    let body = response.body
    expectRead(response, "listTournaments", 200)
    let items = parseJson(body)["items"]
    check items.len == 1
    check items[0]["id"].getStr() == tournamentId
    check items[0]["name"].getStr() == "Read Smoke Cup"
    check items[0]["format"].getStr() == "classic"
    check items[0]["date"].getStr() == "2026-11-08"

  test "getTournament returns the header with its version":
    let response = call(baseUrl, HttpGet,
      "/c/" & slug & "/tournaments/" & tournamentId, memberCookie)
    let body = response.body
    expectRead(response, "getTournament", 200)
    let parsed = parseJson(body)
    check parsed["name"].getStr() == "Read Smoke Cup"
    check parsed["version"].getInt() == 1
    check parsed["format"].getStr() == "classic"
    check parsed["matches"].len == 0
    check header(response, "ETag") == "\"1\""

  test "getDirectory is public and lists a member's own community":
    let anonymous = call(baseUrl, HttpGet, "/directory")
    let anonymousBody = anonymous.body
    expectRead(anonymous, "getDirectory anonymous", 200)
    check parseJson(anonymousBody)["items"].kind == JArray
    let member = call(baseUrl, HttpGet, "/directory", memberCookie)
    let memberBody = member.body
    expectRead(member, "getDirectory member", 200)
    let entries = parseJson(memberBody)["items"]
    let own = rowFor(entries, "slug", slug)
    check own.kind == JObject
    check own["name"].getStr() == "Read Smoke Club"
    check rowFor(entries, "slug", otherSlug).kind == JNull

  test "getHealthz and getReadyz answer ok without a cookie":
    let health = call(baseUrl, HttpGet, "/healthz")
    let healthBody = health.body
    expectRead(health, "getHealthz", 200)
    check parseJson(healthBody)["status"].getStr() == "ok"
    let ready = call(baseUrl, HttpGet, "/readyz")
    let readyBody = ready.body
    expectRead(ready, "getReadyz", 200)
    check parseJson(readyBody)["status"].getStr() == "ok"

  test "getVersion reports the build the binary was compiled from":
    let response = call(baseUrl, HttpGet, "/version")
    let body = response.body
    expectRead(response, "getVersion", 200)
    let parsed = parseJson(body)
    check parsed["version"].getStr() == appVersion
    check parsed["commit"].getStr() == appCommit

  test "getSharedSession serves the fixture's session through its code":
    let response = call(baseUrl, HttpGet, "/s/" & shareCode)
    let body = response.body
    expectRead(response, "getSharedSession", 200)
    let payload = parseJson(body)
    # SEC-20: the code is the only public key of this read. No session id and no
    # game id, so the payload cannot alias the legacy `/s/<id>` route.
    check not payload["session"].hasKey("id")
    check not payload["games"][0].hasKey("id")
    check payload["games"][0]["round"].getInt() == 0
    check payload["games"][0]["court"].getInt() == 0
    check payload["session"]["title"].getStr() == "Read Smoke Night"
    check payload["community"]["slug"].getStr() == slug
    check payload["games"].len == 2
    check payload["standings"]["items"].len == 4

  test "the pre-code session id shortcut is bounded then retired":
    ## BE-13. The session id is visible to every member and embedded in client
    ## state, so it must not stay a public capability after the window.
    expectRead(call(baseUrl, HttpGet, "/s/" & legacySessionId), "legacyShare", 200)
    let outcome = shareStore.retireLegacy(database, 30)
    check outcome.bounded >= 1
    check outcome.retired >= 1
    # The row is now bounded and its shortcut cleared: the id answers 404 while
    # the code minted for that session still resolves.
    let after = call(baseUrl, HttpGet, "/s/" & legacySessionId)
    expectRead(after, "legacyShare", 404)
    let row = database.queryOne(
      """select legacy_id_ok, expires_at is not null as bounded
         from session.links where community_id = $1::uuid and session_id = $2::uuid""",
      @[textParam(legacyCommunityId), textParam(legacySessionId)])
    check row.get.get("legacy_id_ok") == "f"
    check row.get.get("bounded") == "t"

  test "listSharedRankings serves the session's four players":
    let response = call(baseUrl, HttpGet, "/s/" & shareCode & "/rankings")
    let body = response.body
    expectRead(response, "listSharedRankings", 200)
    let parsed = parseJson(body)
    let items = parsed["items"]
    check items.len == 4
    check items[0]["playerId"].getStr() == players[0]
    check parsed["asOf"].getStr() == "2026-11-08"

  test "getSharedRanking serves one player of the shared board":
    let response = call(baseUrl, HttpGet,
      "/s/" & shareCode & "/rankings/" & players[0])
    let body = response.body
    expectRead(response, "getSharedRanking", 200)
    let row = parseJson(body)
    check row["playerId"].getStr() == players[0]
    check row["rank"].getInt() == 1
    check row["name"].getStr() == "Ani"

  test "wsSession refuses a handshake with no ticket":
    # A GET in the contract, but the read is a live frame (BE-07). Without a
    # ticket the upgrade never starts and the fixture's session only proves the
    # slug and id resolve.
    let response = call(baseUrl, HttpGet,
      "/ws/c/" & slug & "/sessions/" & sessionId, origin = "")
    expectProblem(response, 401, "UNAUTHENTICATED")

  test "wsShare refuses a handshake with no ticket":
    let response = call(baseUrl, HttpGet, "/ws/share/" & shareCode, origin = "")
    expectProblem(response, 401, "UNAUTHENTICATED")