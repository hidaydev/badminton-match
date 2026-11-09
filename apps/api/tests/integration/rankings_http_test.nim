import std/[json, options, unittest]
import db/db
import community/infrastructure/community_store
import platform/config/store
import rating/infrastructure/[ingest, ledger, params]
import rating/read
import share/crypto
import share/store as shareStore
import tests/fixtures
import ../http_support

const
  port = testPort(18096)
  baseUrl = "http://127.0.0.1:" & $uint16(port)
  keysJson = """{"1":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="}"""

var
  database: Db
  keyring: Keyring
  communityId, sessionId: string
  memberCookie: string
  players: seq[string]
  # BE-05's rating-sources read gets a community of its own, so the two rows it
  # asserts are the fixture it seeded rather than the board fixture above.
  be05CommunityId, be05SessionId, be05TournamentId: string
  be05Cookie: string
  be05Players: seq[string]

proc bootstrap() =
  database = openDb(dsn(), 1)
  keyring = loadKeyring(keysJson, "1")
  let ownerId = newUser(database, "rank-owner", "rank-owner@example.com",
    "Owner", owner = true)
  communityId = community_store.create(database, "rank-club", "Rank Club",
    "rank-admin@example.com", "Asia/Jakarta", ownerId).communityId
  let memberId = newUser(database, "rank-member", "rank-member@example.com",
    "Member")
  newMember(database, communityId, memberId, "member")
  memberCookie = cookieFor(database, memberId)
  for name in ["Ani", "Budi", "Cakra", "Dewi"]:
    players.add(newPlayer(database, communityId, name))
  sessionId = newSession(database, communityId, "Rank night",
    status = "locked", approved = true)
  for player in players:
    discard database.execUpdate(
      """insert into session.participants
           (community_id, session_id, player_id)
         values ($1::uuid, $2::uuid, $3::uuid)""",
      @[textParam(communityId), textParam(sessionId), textParam(player)])
  # A singles win and a doubles loss for Ani, so history and social tallies
  # have more than one shape to report.
  newGame(database, communityId, sessionId, 1, 1, [players[0]],
    [players[1]], status = "played", scoreA = 21, scoreB = 15)
  discard database.execUpdate(
    """insert into session.game_sets
         (community_id, session_id, round_no, court_no, set_no, score_a, score_b)
       values ($1::uuid, $2::uuid, 1, 1, 1, 21, 15)""",
    @[textParam(communityId), textParam(sessionId)])
  newGame(database, communityId, sessionId, 1, 2,
    [players[0], players[1]], [players[2]], status = "played",
    scoreA = 18, scoreB = 21)
  discard database.execUpdate(
    """insert into session.game_sets
         (community_id, session_id, round_no, court_no, set_no, score_a, score_b)
       values ($1::uuid, $2::uuid, 1, 2, 1, 18, 21)""",
    @[textParam(communityId), textParam(sessionId)])
  # The event and the deltas come from the ingest the API itself runs. The
  # counters then add the two games the exposed history does not show, because
  # the stats fixture covers four games even though only two are on display.
  discard ingestSession(database, communityId, sessionId,
    loadRatingParams(loadSnapshot(database), newJObject()))
  database.tx(proc(conn: DbConn) =
    addState(conn, communityId, @[players[0], players[1]], won = true)
    addState(conn, communityId, @[players[2], players[3]], won = false)
    addState(conn, communityId, @[players[0], players[1]], won = false)
    addState(conn, communityId, @[players[2], players[3]], won = true))
  # Yesterday's snapshot is deliberately in a different order, so rank
  # movement has something to report.
  let yesterday = database.queryOne(
    "select (current_date - 1)::text as day").get.get("day")
  let previous = [100, 500, 300, 50]
  var priorRows: seq[BoardRow] = @[]
  for index, player in players:
    priorRows.add(BoardRow(playerId: player, points: previous[index]))
  discard writeSnapshot(database, communityId, yesterday, priorRows)
  let tournamentId = database.queryOne(
    """insert into tournament.tournaments
         (community_id, name, status, format, event_date)
       values ($1::uuid, 'Rank Open', 'completed', 'classic', current_date)
       returning id""", @[textParam(communityId)]).get.get("id")
  let pairA = database.queryOne(
    """insert into tournament.pairs
         (community_id, tournament_id, display_name, player_a_id, player_b_id)
       values ($1::uuid, $2::uuid, 'Ani/Budi', $3::uuid, $4::uuid)
       returning id""",
    @[textParam(communityId), textParam(tournamentId), textParam(players[0]),
      textParam(players[1])]).get.get("id")
  let pairB = database.queryOne(
    """insert into tournament.pairs
         (community_id, tournament_id, display_name, player_a_id, player_b_id)
       values ($1::uuid, $2::uuid, 'Cakra/Dewi', $3::uuid, $4::uuid)
       returning id""",
    @[textParam(communityId), textParam(tournamentId), textParam(players[2]),
      textParam(players[3])]).get.get("id")
  discard database.execUpdate(
    """insert into tournament.matches
         (community_id, tournament_id, round_no, phase, pair_a_id, pair_b_id,
          score_a, score_b, status)
       values ($1::uuid, $2::uuid, 0, 'group', $3::uuid, $4::uuid, 21, 10,
               'played')""",
    @[textParam(communityId), textParam(tournamentId), textParam(pairA),
      textParam(pairB)])
  for key in ["sessions:10", "rank:5", "tournaments:3", "tier:C"]:
    discard database.execUpdate(
      """insert into achievement.earned
           (community_id, player_id, achievement_key, earned_at)
         values ($1::uuid, $2::uuid, $3, now())""",
      @[textParam(communityId), textParam(players[0]), textParam(key)])
  let be05AdminId = newUser(database, "be05-ratings-admin",
    "be05-ratings-admin@example.com", "BE05 Admin")
  be05CommunityId = newCommunity(database, "be05-ratings", "BE05 Ratings")
  newMember(database, be05CommunityId, be05AdminId, "admin")
  for name in ["Nia", "Oki", "Putri", "Rudi"]:
    be05Players.add(newPlayer(database, be05CommunityId, name))
  be05SessionId = newSession(database, be05CommunityId, "Ingested night",
    status = "locked", approved = true)
  for player in be05Players:
    newParticipant(database, be05CommunityId, be05SessionId, player)
  newGame(database, be05CommunityId, be05SessionId, 1, 1, [be05Players[0]],
    [be05Players[1]], status = "played", scoreA = 21, scoreB = 15)
  discard database.execUpdate(
    """insert into session.game_sets
         (community_id, session_id, round_no, court_no, set_no, score_a, score_b)
       values ($1::uuid, $2::uuid, 1, 1, 1, 21, 15)""",
    @[textParam(be05CommunityId), textParam(be05SessionId)])
  let be05Ingest = ingestSession(database, be05CommunityId, be05SessionId,
    loadRatingParams(loadSnapshot(database), newJObject()))
  doAssert be05Ingest.deltas == 2, "the be05 singles game records two deltas"
  # A tournament that was never ingested has no rating event, so only the
  # second query in listRatingSources can put it on the screen.
  be05TournamentId = database.queryOne(
    """insert into tournament.tournaments
         (community_id, name, status, format, event_date)
       values ($1::uuid, 'BE05 Cup', 'completed', 'classic', current_date)
       returning id""", @[textParam(be05CommunityId)]).get.get("id")
  be05Cookie = cookieFor(database, be05AdminId)
  startServer(newTestApp(database), port, baseUrl)

bootstrap()

suite "rankings HTTP":
  test "members read an ordered board and a player row":
    let status = call(baseUrl, HttpGet, "/c/rank-club/rankings", memberCookie)
    let body = status.body
    expectStatus(status, 200)
    let parsed = parseJson(body)
    let items = parsed["items"]
    # Only players with a rated game inside the window reach the board; Dewi
    # has a delta but no game, so she is not on it.
    check items.len == 3
    check parsed["windowWeeks"].getInt() == 12
    check parsed["bestN"].getInt() == 10
    check parsed["minSessions"].getInt() == 0
    check items[0]["playerId"].getStr() == players[0]
    check items[0]["rank"].getInt() == 1
    check items[0]["points"].getInt() > items[1]["points"].getInt()
    # One entry in the window, below the thin-evidence threshold of three.
    check items[0]["entriesAvailable"].getInt() == 1
    check items[0]["countedEntries"].getInt() == 1
    check items[0]["thinEvidence"].getBool()
    # Yesterday's snapshot ranked Ani third, so she moved up two places.
    check items[0]["prevRank"].getInt() == 3
    check items[0]["rankDelta"].getInt() == 2
    let breakdown = items[0]["breakdown"]
    check breakdown.len == 1
    check breakdown[0]["sourceId"].getStr() == sessionId
    check breakdown[0]["kind"].getStr() == "session"
    # One entry, so its points are the whole row.
    check int(breakdown[0]["points"].getFloat() + 0.5) == items[0]["points"].getInt()
    check breakdown[0]["games"].getInt() == 2
    let detail = call(baseUrl, HttpGet,
      "/c/rank-club/rankings/" & players[1], memberCookie)
    let detailBody = detail.body
    expectStatus(detail, 200)
    let row = parseJson(detailBody)
    check row["rank"].getInt() == 2
    # The detail anchors on the same event as the board, so the points match.
    check row["points"].getInt() == items[1]["points"].getInt()
    check row["prevRank"].getInt() == 1
    check row["rankDelta"].getInt() == -1
    check row["countedEntries"].getInt() == 1
    check row["breakdown"][0]["sourceId"].getStr() == sessionId

  test "the tier filter is applied by the server":
    let status = call(baseUrl, HttpGet, "/c/rank-club/rankings?tier=B", memberCookie)
    let body = status.body
    expectStatus(status, 200)
    let items = parseJson(body)["items"]
    check items.len == 0
    discard database.execUpdate(
      """update player.players set tier = 'B' where id = $1::uuid""",
      @[textParam(players[0])])
    let filteredStatus = call(baseUrl, HttpGet, "/c/rank-club/rankings?tier=B",
      memberCookie)
    let filteredBody = filteredStatus.body
    expectStatus(filteredStatus, 200)
    let filtered = parseJson(filteredBody)["items"]
    check filtered.len == 1
    check filtered[0]["playerId"].getStr() == players[0]

  test "a plus in the tier query survives form decoding":
    discard database.execUpdate(
      """update player.players set tier = 'C+' where id = $1::uuid""",
      @[textParam(players[1])])
    # A raw `+` in a query string means space, so a hand-written link arrives
    # here as "C ".
    let status = call(baseUrl, HttpGet, "/c/rank-club/rankings?tier=C+", memberCookie)
    let body = status.body
    expectStatus(status, 200)
    let items = parseJson(body)["items"]
    check items.len == 1
    check items[0]["playerId"].getStr() == players[1]
    # A tier outside the ladder is ignored instead of emptying the board.
    let allBody = call(baseUrl, HttpGet, "/c/rank-club/rankings", memberCookie).body
    let allItems = parseJson(allBody)["items"].len
    check allItems >= 3
    let unknownStatus = call(baseUrl, HttpGet, "/c/rank-club/rankings?tier=Z",
      memberCookie)
    let unknownBody = unknownStatus.body
    expectStatus(unknownStatus, 200)
    check parseJson(unknownBody)["items"].len == allItems

  test "the player ranking honours the same min_sessions filter":
    let status = call(baseUrl, HttpGet, "/c/rank-club/rankings/" & players[0],
      memberCookie)
    let row = status.body
    expectStatus(status, 200)
    check parseJson(row)["minSessions"].getInt() == 0
    let filteredOut = call(baseUrl, HttpGet,
      "/c/rank-club/rankings/" & players[0] & "?min_sessions=99", memberCookie)
    expectProblem(filteredOut, 404)

  test "an unknown player or a non-member gets 404":
    let missing = call(baseUrl, HttpGet, "/c/rank-club/rankings/00000000-0000-0000-0000-000000000000",
      memberCookie)
    expectProblem(missing, 404)
    let foreign = call(baseUrl, HttpGet, "/c/rank-club/rankings")
    expectProblem(foreign, 401)

  test "stats show the board's points, not a second rating":
    let status = call(baseUrl, HttpGet, "/c/rank-club/players/" & players[0] & "/stats",
      memberCookie)
    let body = status.body
    expectStatus(status, 200)
    let stats = parseJson(body)
    check stats["name"].getStr() == "Ani"
    # Counters are counts and stay on the ledger.
    check stats["games"].getInt() == 4
    check stats["wins"].getInt() == 2
    # The detail number and the leaderboard row must be the same read, so a
    # player never sees two different scores for themselves.
    let rankStatus = call(baseUrl, HttpGet,
      "/c/rank-club/rankings/" & players[0], memberCookie)
    let rankBody = rankStatus.body
    expectStatus(rankStatus, 200)
    check stats["points"].getInt() == parseJson(rankBody)["points"].getInt()

  test "stats carry history, sessions and social tallies":
    let status = call(baseUrl, HttpGet, "/c/rank-club/players/" & players[0] & "/stats",
      memberCookie)
    let body = status.body
    expectStatus(status, 200)
    let stats = parseJson(body)
    let history = stats["history"]
    check history.len == 2
    # Newest first, then the higher court number inside a round.
    check history[0]["gameRef"].getStr() == "1-2"
    check history[0]["outcome"].getStr() == "L"
    check history[0]["scoreA"].getInt() == 18
    check history[0]["scoreB"].getInt() == 21
    check history[0]["teammates"][0].getStr() == "Budi"
    check history[0]["opponents"][0].getStr() == "Cakra"
    check history[1]["gameRef"].getStr() == "1-1"
    check history[1]["outcome"].getStr() == "W"
    check history[1]["teammates"].len == 0
    let sessions = stats["sessions"]
    check sessions.len == 1
    check sessions[0]["id"].getStr() == sessionId
    check sessions[0]["title"].getStr() == "Rank night"
    check not sessions[0]["absent"].getBool()
    let partners = stats["topPartners"]
    check partners.len == 1
    check partners[0]["name"].getStr() == "Budi"
    check partners[0]["count"].getInt() == 1
    check partners[0]["wins"].getInt() == 0
    check partners[0]["losses"].getInt() == 1
    let opponents = stats["topOpponents"]
    check opponents.len == 2
    check opponents[0]["name"].getStr() == "Budi"
    check opponents[0]["wins"].getInt() == 1
    check opponents[1]["name"].getStr() == "Cakra"
    check opponents[1]["losses"].getInt() == 1

  test "tournament stats count classic matches":
    let status = call(baseUrl, HttpGet, "/c/rank-club/players/" & players[0] & "/stats",
      memberCookie)
    let body = status.body
    expectStatus(status, 200)
    let tournament = parseJson(body)["tournamentStats"]
    check tournament["gamesPlayed"].getInt() == 1
    check tournament["wins"].getInt() == 1
    check tournament["losses"].getInt() == 0
    check tournament["tournaments"].len == 1
    check tournament["tournaments"][0]["name"].getStr() == "Rank Open"
    check tournament["tournaments"][0]["games"].getInt() == 1
    check tournament["topPartners"][0]["name"].getStr() == "Budi"
    check tournament["topPartners"][0]["wins"].getInt() == 1
    check tournament["topOpponents"].len == 2

  test "the session list counts players and games":
    let status = call(baseUrl, HttpGet, "/c/rank-club/sessions", memberCookie)
    let body = status.body
    expectStatus(status, 200)
    let items = parseJson(body)["items"]
    var found = false
    for item in items:
      if item["id"].getStr() == sessionId:
        found = true
        check item["playerCount"].getInt() == 4
        check item["totalGames"].getInt() == 2
    check found

  test "achievements carry the catalog labels and ladder":
    let status = call(baseUrl, HttpGet,
      "/c/rank-club/players/" & players[0] & "/achievements", memberCookie)
    let body = status.body
    expectStatus(status, 200)
    let items = parseJson(body)["items"]
    check items.len == 4
    for item in items:
      check item["kind"].getStr() == item["category"].getStr()
      check item.hasKey("detail")
      check item["note"].getStr() == ""
      check item["value"].getInt() == item["threshold"].getInt()
      check item["thresholds"].len >= 1
      check item["meta"].kind == JObject
    for item in items:
      case item["key"].getStr()
      of "sessions:10":
        check item["title"].getStr() == "Sessions 10"
        check item["thresholds"].len == 5
        check item["tierLevel"].getInt() == 2
        check item["tierName"].getStr() == "Silver"
        check item["nextTarget"].getInt() == 15
      of "rank:5":
        # Rank improves downward, so the ladder starts at the loosest rank.
        check item["thresholds"][0].getInt() == 10
        check item["tierLevel"].getInt() == 2
        check item["nextTarget"].getInt() == 3
      of "tournaments:3":
        check item["thresholds"].len == 3
        check item["tierName"].getStr() == "Silver"
      of "tier:C":
        check item["title"].getStr() == "Tier C"
        check item["tierLevel"].kind == JNull
        check item["tierName"].kind == JNull
        check item["meta"]["tier"].getStr() == "C"
      else:
        check false

  test "the public board resolves through a share code":
    let ownerId = database.queryOne(
      """select id from platform.user where google_sub = 'rank-owner'"""
      ).get.get("id")
    let code = shareStore.issue(database, keyring, communityId, sessionId, ownerId, 30)
    let status = call(baseUrl, HttpGet, "/s/" & code & "/rankings")
    let body = status.body
    expectStatus(status, 200)
    check parseJson(body)["items"].len == 3
    let unknown = call(baseUrl, HttpGet, "/s/nope/rankings")
    expectProblem(unknown, 404)

  test "the public player detail resolves through the same share code":
    let ownerId = database.queryOne(
      """select id from platform.user where google_sub = 'rank-owner'"""
      ).get.get("id")
    let code = shareStore.issue(database, keyring, communityId, sessionId, ownerId, 30)
    let status = call(baseUrl, HttpGet, "/s/" & code & "/rankings/" & players[0])
    let body = status.body
    expectStatus(status, 200)
    check parseJson(body)["rank"].getInt() == 1
    check parseJson(body)["playerId"].getStr() == players[0]
    let missing = call(baseUrl, HttpGet, "/s/" & code &
      "/rankings/00000000-0000-0000-0000-000000000000")
    expectProblem(missing, 404)
    let unknown = call(baseUrl, HttpGet, "/s/nope/rankings/" & players[0])
    expectProblem(unknown, 404)

  test "revoking the share link kills the public code":
    let ownerId = database.queryOne(
      """select id from platform.user where google_sub = 'rank-owner'"""
      ).get.get("id")
    let adminId = newUser(database, "rank-admin", "rank-admin@example.com",
      "Rank Admin")
    newMember(database, communityId, adminId, "admin")
    let adminCookie = cookieFor(database, adminId)
    let code = shareStore.issue(database, keyring, communityId, sessionId, ownerId, 30)
    let live = call(baseUrl, HttpGet, "/s/" & code)
    expectStatus(live, 200)
    let path = "/c/rank-club/sessions/" & sessionId & "/share"
    let revoked = call(baseUrl, HttpDelete, path, adminCookie)
    expectStatus(revoked, 204)
    let gone = call(baseUrl, HttpGet, "/s/" & code)
    expectProblem(gone, 404)
    let again = call(baseUrl, HttpDelete, path, adminCookie)
    expectProblem(again, 404)

  test "finalizing a rating source protects it from a revert":
    let adminId = database.queryOne(
      """select user_id from community.membership m
         join platform.user u on u.id = m.user_id
         where u.google_sub = 'rank-admin' limit 1""").get.get("user_id")
    let adminCookie = cookieFor(database, adminId)
    let eventId = database.queryOne(
      """select id from rating.events
         where community_id = $1::uuid and source_id = $2::uuid""",
      @[textParam(communityId), textParam(sessionId)]).get.get("id")
    let path = "/c/rank-club/rating-sources/" & eventId
    let asMember = call(baseUrl, HttpGet, path, memberCookie)
    expectProblem(asMember, 403)
    let badBody = call(baseUrl, HttpPatch, path, adminCookie,
      """{"finalized":"yes"}""")
    expectProblem(badBody, 400)
    let missing = call(baseUrl, HttpPatch,
      "/c/rank-club/rating-sources/00000000-0000-0000-0000-000000000000",
      adminCookie, """{"finalized":true}""")
    expectProblem(missing, 404)
    let finalized = call(baseUrl, HttpPatch, path, adminCookie,
      """{"finalized":true}""")
    let finalizedBody = finalized.body
    expectStatus(finalized, 200)
    check parseJson(finalizedBody)["finalized"].getBool()
    let refused = call(baseUrl, HttpDelete,
      "/c/rank-club/sessions/" & sessionId & "/rating", adminCookie)
    expectProblem(refused, 403)
    let unfinalized = call(baseUrl, HttpPatch, path, adminCookie,
      """{"finalized":false}""")
    let unfinalizedBody = unfinalized.body
    expectStatus(unfinalized, 200)
    check not parseJson(unfinalizedBody)["finalized"].getBool()
    # Withdrawing the sign-off is not enough: the session is still approved, so
    # the rebuild would re-ingest the event and the undo would be a no-op.
    let stillApproved = call(baseUrl, HttpDelete,
      "/c/rank-club/sessions/" & sessionId & "/rating", adminCookie)
    expectProblem(stillApproved, 409)
    discard database.execUpdate(
      """update session.sessions set status = 'draft', approved_at = null
         where id = $1::uuid""", @[textParam(sessionId)])
    let reverted = call(baseUrl, HttpDelete,
      "/c/rank-club/sessions/" & sessionId & "/rating", adminCookie)
    expectStatus(reverted, 200)
    # The undo really removed the event now (it used to be re-ingested at once),
    # so put the shared session back: later tests read the board it feeds.
    discard database.execUpdate(
      """update session.sessions set status = 'locked', approved_at = now()
         where id = $1::uuid""", @[textParam(sessionId)])
    let rebuiltAfterUndo = call(baseUrl, HttpPost, "/c/rank-club/ratings/rebuild",
      adminCookie)
    expectStatus(rebuiltAfterUndo, 202)
    check parseJson(rebuiltAfterUndo.body)["status"].getStr() == "accepted"
    check parseJson(rebuiltAfterUndo.body)["job"].getStr().len > 0
    # The replay runs on the worker, so wait for it before the following tests
    # read the board.
    waitForRatingJobs()
    check database.queryOne(
      """select 1 as ok from rating.events
         where community_id = $1::uuid and event_type = 'session'
           and source_id = $2::uuid""",
      @[textParam(communityId), textParam(sessionId)]).isSome

  test "removing a rating source queues the replay instead of running it":
    # The delete and its evidence share one transaction; the ledger replay is a
    # worker job. Holding the request open for the replay is the BE-01 outage.
    let adminId = database.queryOne(
      """select user_id from community.membership m
         join platform.user u on u.id = m.user_id
         where u.google_sub = 'rank-admin' limit 1""").get.get("user_id")
    let adminCookie = cookieFor(database, adminId)
    let eventId = database.queryOne(
      """select id from rating.events
         where community_id = $1::uuid and source_id = $2::uuid""",
      @[textParam(communityId), textParam(sessionId)]).get.get("id")
    discard database.execUpdate(
      """update session.sessions set status = 'draft', approved_at = null
         where id = $1::uuid""", @[textParam(sessionId)])
    let status = call(baseUrl, HttpDelete,
      "/c/rank-club/rating-sources/" & eventId, adminCookie)
    expectStatus(status, 200)
    check parseJson(status.body)["removedDeltas"].kind == JInt
    check database.queryOne(
      """select 1 as ok from rating.events where id = $1::uuid""",
      @[textParam(eventId)]).isNone
    waitForRatingJobs()
    check database.queryOne(
      """select 1 as ok from rating.events where id = $1::uuid""",
      @[textParam(eventId)]).isNone
    # Put the shared fixture back the way the following tests expect it.
    discard database.execUpdate(
      """update session.sessions set status = 'locked', approved_at = now()
         where id = $1::uuid""", @[textParam(sessionId)])
    let rebuild = call(baseUrl, HttpPost, "/c/rank-club/ratings/rebuild",
      adminCookie)
    expectStatus(rebuild, 202)
    waitForRatingJobs()
    check database.queryOne(
      """select 1 as ok from rating.events
         where community_id = $1::uuid and event_type = 'session'
           and source_id = $2::uuid""",
      @[textParam(communityId), textParam(sessionId)]).isSome

  test "a share code publishes only the players of its session":
    # A second session puts one more player on the community board, so the
    # public copy and the member page can be told apart.
    let outsider = newPlayer(database, communityId, "Eka", "F")
    let otherSession = newSession(database, communityId, "Second night",
      status = "locked", approved = true)
    for player in [players[1], outsider]:
      discard database.execUpdate(
        """insert into session.participants
             (community_id, session_id, player_id)
           values ($1::uuid, $2::uuid, $3::uuid)""",
        @[textParam(communityId), textParam(otherSession), textParam(player)])
    newGame(database, communityId, otherSession, 1, 1, [outsider],
      [players[1]], status = "played", scoreA = 21, scoreB = 10)
    discard database.execUpdate(
      """insert into session.game_sets
           (community_id, session_id, round_no, court_no, set_no, score_a, score_b)
         values ($1::uuid, $2::uuid, 1, 1, 1, 21, 10)""",
      @[textParam(communityId), textParam(otherSession)])
    discard ingestSession(database, communityId, otherSession,
      loadRatingParams(loadSnapshot(database), newJObject()))
    let memberStatus = call(baseUrl, HttpGet, "/c/rank-club/rankings", memberCookie)
    let memberBody = memberStatus.body
    expectStatus(memberStatus, 200)
    check parseJson(memberBody)["items"].len == 4
    let ownerId = database.queryOne(
      """select id from platform.user where google_sub = 'rank-owner'"""
      ).get.get("id")
    let code = shareStore.issue(database, keyring, communityId, sessionId, ownerId, 30)
    let status = call(baseUrl, HttpGet, "/s/" & code & "/rankings")
    let body = status.body
    expectStatus(status, 200)
    let items = parseJson(body)["items"]
    check items.len == 3
    for item in items:
      check item["playerId"].getStr() in players[0 .. 2]
      check item["playerId"].getStr() != outsider
    # The outsider is on the community board, not behind a forwarded code.
    let outsiderDetail = call(baseUrl, HttpGet, "/s/" & code & "/rankings/" & outsider)
    expectProblem(outsiderDetail, 404)
    let memberDetail = call(baseUrl, HttpGet, "/s/" & code & "/rankings/" &
      players[0])
    let memberDetailBody = memberDetail.body
    expectStatus(memberDetail, 200)
    check parseJson(memberDetailBody)["playerId"].getStr() == players[0]

  test "rating sources list an ingested session and a never-ingested tournament":
    let today = database.queryOne(
      "select current_date::text as day").get.get("day")
    let status = call(baseUrl, HttpGet, "/c/be05-ratings/rating-sources",
      be05Cookie)
    let body = status.body
    expectStatus(status, 200)
    let items = parseJson(body)["items"]
    # Exactly the two this community owns: the rank-club event must not leak.
    check items.len == 2
    var sessionRow, tournamentRow: JsonNode
    for item in items:
      if item["sourceId"].getStr() == be05SessionId:
        sessionRow = item
      elif item["sourceId"].getStr() == be05TournamentId:
        tournamentRow = item
    check sessionRow.kind == JObject
    check tournamentRow.kind == JObject
    check sessionRow["type"].getStr() == "session"
    check sessionRow["date"].getStr() == today
    check sessionRow["deltas"].getInt() == 2
    check not sessionRow["finalized"].getBool()
    check sessionRow["finalizedAt"].kind == JNull
    check tournamentRow["type"].getStr() == "tournament"
    check tournamentRow["date"].getStr() == today
    # No event row stands behind this one, so its count comes from the second
    # query and stays zero until the bracket is ingested.
    check tournamentRow["deltas"].getInt() == 0
    check not tournamentRow["finalized"].getBool()
    # Signing the session off is what the `finalized` join reports back.
    let signOff = call(baseUrl, HttpPatch,
      "/c/be05-ratings/rating-sources/" & sessionRow["id"].getStr(), be05Cookie,
      """{"finalized":true}""")
    expectStatus(signOff, 200)
    let rereadStatus = call(baseUrl, HttpGet,
      "/c/be05-ratings/rating-sources", be05Cookie)
    let rereadBody = rereadStatus.body
    expectStatus(rereadStatus, 200)
    var signedOff: JsonNode
    for item in parseJson(rereadBody)["items"]:
      if item["sourceId"].getStr() == be05SessionId:
        signedOff = item
    check signedOff["finalized"].getBool()
    check signedOff["finalizedAt"].kind == JString
    check signedOff["deltas"].getInt() == 2
