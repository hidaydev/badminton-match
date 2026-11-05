import std/[json, math, options, os, strutils, unittest]
import db/db
import ../../read
import ../../domain/rating

var
  database: Db
  communityId: string
  players: seq[string]

const asOf = "2026-11-04"

proc dsn(): string = getEnv("MAJADU_PG_DSN")

proc params(): RatingParams =
  RatingParams(sessionBase: 250, scoreTarget: 21, opponentClampLow: 0.5,
    opponentClampHigh: 1.5, windowWeeks: 12, bestN: 10, thinEvidenceN: 3,
    bands: @[
      TierBand(tier: "D", floor: 1000, ceiling: some(1199.0)),
      TierBand(tier: "C", floor: 1300, ceiling: some(1499.0)),
      TierBand(tier: "B", floor: 1600, ceiling: some(1799.0)),
      TierBand(tier: "A+", floor: 2100, ceiling: none(float))])

proc query(tier = ""): BoardQuery =
  BoardQuery(communityId: communityId, asOf: asOf, params: params(),
    limit: 200, tier: tier)

proc queryAll(): BoardQuery =
  ## No board cap, so a test can see a player the production limit would cut.
  BoardQuery(communityId: communityId, asOf: asOf, params: params(),
    limit: 0, tier: "")

proc cleanup() =
  for statement in [
    """delete from tournament.team_partai where community_id in
         (select id from platform.community where slug = 'read-club')""",
    """delete from tournament.team_matches where community_id in
         (select id from platform.community where slug = 'read-club')""",
    """delete from tournament.team_players where community_id in
         (select id from platform.community where slug = 'read-club')""",
    """delete from tournament.teams where community_id in
         (select id from platform.community where slug = 'read-club')""",
    """delete from tournament.matches where community_id in
         (select id from platform.community where slug = 'read-club')""",
    """delete from tournament.pairs where community_id in
         (select id from platform.community where slug = 'read-club')""",
    """delete from tournament.tournaments where community_id in
         (select id from platform.community where slug = 'read-club')""",
    """delete from rating.snapshots where community_id in
         (select id from platform.community where slug = 'read-club')""",
    """delete from rating.levels where community_id in
         (select id from platform.community where slug = 'read-club')""",
    """delete from rating.deltas where community_id in
         (select id from platform.community where slug = 'read-club')""",
    """delete from rating.events where community_id in
         (select id from platform.community where slug = 'read-club')""",
    """delete from session.games where community_id in
         (select id from platform.community where slug = 'read-club')""",
    """delete from session.sessions where community_id in
         (select id from platform.community where slug = 'read-club')""",
    """delete from rating.player_state where community_id in
         (select id from platform.community where slug = 'read-club')""",
    """delete from player.players where community_id in
         (select id from platform.community where slug = 'read-club')""",
    "delete from platform.community where slug = 'read-club'"]:
    discard database.execUpdate(statement)

proc addSession(age: int, roster: seq[string]) {.discardable.} =
  ## One locked, rated session with two games over the same four players, so
  ## each of them earns one entry worth the sum of two games.
  let sessionId = database.queryOne(
    """insert into session.sessions
         (community_id, title, session_date, status, source, approved_at)
       values ($1::uuid, 'Read session', $2::date - $3::int, 'locked',
               'generator', now())
       returning id""",
    @[textParam(communityId), textParam(asOf), intParam(age.int64)]).get.get("id")
  discard database.execUpdate(
    """insert into rating.events (community_id, local_date, event_type, source_id)
       values ($1::uuid, $2::date - $3::int, 'session', $4::uuid)""",
    @[textParam(communityId), textParam(asOf), intParam(age.int64),
      textParam(sessionId)])
  for player in roster:
    discard database.execUpdate(
      """insert into session.participants
           (community_id, session_id, player_id, is_absent)
         values ($1::uuid, $2::uuid, $3::uuid, false)
         on conflict do nothing""",
      @[textParam(communityId), textParam(sessionId), textParam(player)])
  for game in 0 ..< 2:
    let a1 = roster[0]
    let a2 = roster[1]
    let b1 = roster[2]
    let b2 = roster[3]
    discard database.execUpdate(
      """insert into session.games
           (community_id, session_id, round_no, court_no, score_a, score_b,
            status, side_a1, side_a2, side_b1, side_b2)
         values ($1::uuid, $2::uuid, $3::int, 0, $4::int, 20, 'played',
                 $5::uuid, $6::uuid, $7::uuid, $8::uuid)""",
      @[textParam(communityId), textParam(sessionId), intParam(game.int64),
        textParam($(30 - game)),
        textParam(a1), textParam(a2), textParam(b1), textParam(b2)])

proc seed() =
  communityId = database.queryOne(
    """insert into platform.community (slug, name, timezone)
       values ('read-club', 'Read Club', 'Asia/Jakarta') returning id""").get.get("id")
  for index in 0 ..< 220:
    let id = database.queryOne(
      """insert into player.players (community_id, canonical_name, gender, tier)
         values ($1::uuid, $2, 'M', nullif($3, '')) returning id""",
      @[textParam(communityId), textParam("Read " & align($index, 3)),
        textParam(if index mod 2 == 0: "B" else: "")]).get.get("id")
    players.add(id)
  # Ten players only appear in sessions older than the window.
  for sessionIndex in 0 ..< 10:
    var roster: seq[string] = @[]
    for slot in 0 ..< 4:
      roster.add(players[210 + (sessionIndex * 4 + slot) mod 10])
    addSession(200, roster)
  # Sixty sessions inside the window, four fresh players each time.
  for sessionIndex in 0 ..< 60:
    let base = (sessionIndex * 4) mod 210
    addSession(sessionIndex, @[players[base],
      players[(base + 1) mod 210], players[(base + 2) mod 210],
      players[(base + 3) mod 210]])
  for player in players:
    discard database.execUpdate(
      """insert into rating.player_state
           (community_id, player_id, rating, games_played, wins, losses)
       values ($1::uuid, $2::uuid, 1200, 5, 3, 2)
       on conflict (community_id, player_id) do nothing""",
      @[textParam(communityId), textParam(player)])

proc newPlayer(name: string): string =
  ## A player with no sessions yet, so a test sees only the entries it adds.
  database.queryOne(
    """insert into player.players (community_id, canonical_name, gender, tier)
       values ($1::uuid, $2, 'M', null) returning id""",
    @[textParam(communityId), textParam(name)]).get.get("id")

proc socialCount(rows: JsonNode, name: string): int =
  for entry in rows:
    if entry["name"].getStr() == name:
      return entry["count"].getInt()
  0

proc addEmptySession(playerId: string, age: int) =
  ## A session with no games: enough for the player's session list.
  let id = database.queryOne(
    """insert into session.sessions
         (community_id, title, session_date, status, source)
       values ($1::uuid, 'Session list', $2::date - $3::int, 'draft',
               'generator')
       returning id""",
    @[textParam(communityId), textParam(asOf), intParam(age.int64)])
    .get.get("id")
  discard database.execUpdate(
    """insert into session.participants (community_id, session_id, player_id)
       values ($1::uuid, $2::uuid, $3::uuid)""",
    @[textParam(communityId), textParam(id), textParam(playerId)])

proc skipRoundZero(playerId: string) =
  ## Marks one player as sitting out round 0 of every session they played.
  discard database.execUpdate(
    """insert into session.game_skips
         (community_id, session_id, round_no, court_no, player_id)
       select $1::uuid, g.session_id, g.round_no, g.court_no, $2::uuid
       from session.games g
       where g.community_id = $1::uuid and g.round_no = 0
         and (g.side_a1 = $2::uuid or g.side_a2 = $2::uuid
              or g.side_b1 = $2::uuid or g.side_b2 = $2::uuid)""",
    @[textParam(communityId), textParam(playerId)])

proc addClassicTournament(age: int, withLevel: bool, winnerScore,
                          loserScore: int, sideA, sideB: seq[string]): string =
  ## One completed classic bracket: a single final between two pairs. The
  ## rating event points at the tournament, exactly like the ETL writes it.
  let tournamentId = database.queryOne(
    """insert into tournament.tournaments
         (community_id, name, status, format, event_date)
       values ($1::uuid, 'Read Cup', 'completed', 'classic', $2::date - $3::int)
       returning id""",
    @[textParam(communityId), textParam(asOf), intParam(age.int64)]).get.get("id")
  let pairA = database.queryOne(
    """insert into tournament.pairs
         (community_id, tournament_id, display_name, player_a_id, player_b_id)
       values ($1::uuid, $2::uuid, 'A/B', $3::uuid, $4::uuid) returning id""",
    @[textParam(communityId), textParam(tournamentId), textParam(sideA[0]),
      textParam(sideA[1])]).get.get("id")
  let pairB = database.queryOne(
    """insert into tournament.pairs
         (community_id, tournament_id, display_name, player_a_id, player_b_id)
       values ($1::uuid, $2::uuid, 'C/D', $3::uuid, $4::uuid) returning id""",
    @[textParam(communityId), textParam(tournamentId), textParam(sideB[0]),
      textParam(sideB[1])]).get.get("id")
  discard database.execUpdate(
    """insert into tournament.matches
         (community_id, tournament_id, round_no, phase, pair_a_id, pair_b_id,
          score_a, score_b, status, match_key)
       values ($1::uuid, $2::uuid, 0, 'final', $3::uuid, $4::uuid, $5::int,
               $6::int, 'played', 'final-1')""",
    @[textParam(communityId), textParam(tournamentId), textParam(pairA),
      textParam(pairB), textParam($winnerScore), textParam($loserScore)])
  discard database.execUpdate(
    """insert into rating.events (community_id, local_date, event_type, source_id)
       values ($1::uuid, $2::date - $3::int, 'tournament', $4::uuid)""",
    @[textParam(communityId), textParam(asOf), intParam(age.int64),
      textParam(tournamentId)])
  if withLevel:
    discard database.execUpdate(
      """insert into rating.levels
           (community_id, kind, champion_points, round_ratios, enabled)
         values ($1::uuid, 'tournament_classic', 2500,
                 '{"final":1.0,"runner_up":0.85,"sf":0.7,"qf":0.55,"group":0.4,"participant":0.2}'::jsonb,
                 true)
         on conflict (community_id, kind) do nothing""",
      @[textParam(communityId)])
  tournamentId

database = openDb(dsn(), 1)
cleanup()
seed()

suite "ranking read":
  test "the board is capped, ordered and only counts the window":
    let rows = board(database, query())
    check rows.len == 200
    for index in 1 ..< rows.len:
      check rows[index - 1].points >= rows[index].points
    # Players whose only sessions are older than the window never appear.
    for index in 210 ..< 220:
      check boardEntry(database, query(), players[index]).isNone

  test "the best N entries are summed, not every entry":
    let heavy = players[0]
    let before = boardEntry(database, query(), heavy).get.entriesAvailable
    for extra in 0 ..< 15:
      addSession(1, @[heavy, players[1], players[2], players[3]])
    let entry = boardEntry(database, query(), heavy)
    check entry.isSome
    check entry.get.entriesAvailable == before + 15
    check entry.get.countedEntries == 10
    var total = 0.0
    for index in 0 ..< 10:
      total += entry.get.breakdown[index].points
    check entry.get.points == int(round(total))
    check rankOf(database, query(), heavy) == 1

  test "a snapshot matches the board on the same day":
    let rows = board(database, query())
    check writeSnapshot(database, communityId, asOf, rows) == rows.len
    check writeSnapshot(database, communityId, asOf, rows) == rows.len
    let snapshot = snapshotRows(database, communityId, asOf)
    check snapshot.len == rows.len
    for index in 0 ..< rows.len:
      check snapshot[index].playerId == rows[index].playerId
      check snapshot[index].points == rows[index].points

  test "every row reports its window evidence and breakdown":
    let rows = board(database, query())
    check rows.len > 0
    for row in rows:
      check row.entriesAvailable >= row.countedEntries
      check row.countedEntries == min(10, row.entriesAvailable)
      check row.breakdown.len == row.countedEntries
      check row.thinEvidence == (row.entriesAvailable < 3)
      for index in 1 ..< row.breakdown.len:
        check row.breakdown[index - 1].points >= row.breakdown[index].points
      for entry in row.breakdown:
        check entry.kind == "session"
        check entry.date.len == 10
        check entry.sourceId.isSome
        check entry.games == 2

  test "rank movement comes from the latest earlier snapshot":
    let rows = board(database, query())
    for index, row in rows:
      discard database.execUpdate(
        """insert into rating.snapshots
             (community_id, player_id, taken_on, rating)
           values ($1::uuid, $2::uuid, '2026-10-01', $3)
           on conflict (community_id, player_id, taken_on) do update
             set rating = excluded.rating""",
        @[textParam(communityId), textParam(row.playerId),
          intParam(index.int64)])
    let moved = board(database, query())
    check moved.len == rows.len
    # The snapshot rated the current leader lowest, so the leader moved up.
    check moved[0].prevRank == some(rows.len)
    check moved[0].rankDelta == some(rows.len - 1)
    # A leaderboard without a snapshot has no movement to report.
    for row in board(database, BoardQuery(communityId: communityId,
        asOf: "2026-10-01", params: params(), limit: 5, tier: "")):
      check row.prevRank.isNone
      check row.rankDelta.isNone

  test "a tier filter narrows the board":
    let all = board(database, query())
    let filtered = board(database, query("B"))
    check filtered.len > 0
    check filtered.len < all.len
    for row in filtered:
      check row.tier == "B"

  test "stats and unknown players":
    let found = stats(database, communityId, players[0])
    check found.isSome
    check found.get["games"].getInt() == 5
    check stats(database, communityId,
      "00000000-0000-0000-0000-000000000000").isNone

  test "a tournament with a ladder pays the champion and the placement":
    let sideA = @[newPlayer("Cup A1"), newPlayer("Cup A2")]
    let sideB = @[newPlayer("Cup B1"), newPlayer("Cup B2")]
    discard addClassicTournament(2, withLevel = true, winnerScore = 21,
      loserScore = 10, sideA, sideB)
    let champion = boardEntry(database, queryAll(), sideA[0])
    check champion.isSome
    check champion.get.entriesAvailable == 1
    check champion.get.points == 2500
    check champion.get.breakdown[0].kind == "tournament_classic"
    check champion.get.breakdown[0].points == 2500.0
    # A finalist that won nothing is a participant, the loosest rung.
    let finalist = boardEntry(database, queryAll(), sideB[0])
    check finalist.isSome
    check finalist.get.points == 500

  test "a tournament without a ladder falls back to the game formula":
    discard database.execUpdate(
      """update rating.levels set enabled = false
         where community_id = $1::uuid""", @[textParam(communityId)])
    let sideA = @[newPlayer("Fallback A1"), newPlayer("Fallback A2")]
    let sideB = @[newPlayer("Fallback B1"), newPlayer("Fallback B2")]
    discard addClassicTournament(3, withLevel = false, winnerScore = 21,
      loserScore = 10, sideA, sideB)
    let entry = boardEntry(database, queryAll(), sideA[0])
    check entry.isSome
    # The final target is 42, not the session target, so an 11-point margin is
    # worth 250 * (0.5 + 0.5 * 11/42), rounded once at the edge.
    check entry.get.points == int(round(250.0 * (0.5 + 0.5 * 11.0 / 42.0)))

  test "a skipped or absent player does not score that game":
    let roster = @[newPlayer("Skip A1"), newPlayer("Skip A2"),
      newPlayer("Skip B1"), newPlayer("Skip B2")]
    addSession(4, roster)
    discard database.execUpdate(
      """update session.participants set is_absent = true
         where community_id = $1::uuid and player_id = $2::uuid""",
      @[textParam(communityId), textParam(roster[0])])
    discard database.execUpdate(
      """insert into session.game_skips
           (community_id, session_id, round_no, court_no, player_id)
         select $1::uuid, g.session_id, g.round_no, g.court_no, $2::uuid
         from session.games g
         where g.community_id = $1::uuid and g.round_no = 0
           and (g.side_a1 = $2::uuid or g.side_a2 = $2::uuid
                or g.side_b1 = $2::uuid or g.side_b2 = $2::uuid)""",
      @[textParam(communityId), textParam(roster[1])])
    check boardEntry(database, queryAll(), roster[0]).isNone
    let skipped = boardEntry(database, queryAll(), roster[1])
    check skipped.isSome
    check skipped.get.breakdown[0].games == 1
    let teammate = boardEntry(database, queryAll(), roster[2])
    check teammate.isSome
    check teammate.get.breakdown[0].games == 2

  test "the window edge is inclusive and the board knows its last day":
    let inside = @[newPlayer("Edge In 1"), newPlayer("Edge In 2"),
      newPlayer("Edge In 3"), newPlayer("Edge In 4")]
    let outside = @[newPlayer("Edge Out 1"), newPlayer("Edge Out 2"),
      newPlayer("Edge Out 3"), newPlayer("Edge Out 4")]
    addSession(84, inside)
    addSession(85, outside)
    check boardEntry(database, queryAll(), inside[0]).isSome
    check boardEntry(database, queryAll(), outside[0]).isNone
    check latestEventDate(database, communityId) == asOf

  test "history leaves out unapproved sessions and skipped games":
    let roster = @[newPlayer("Hist A"), newPlayer("Hist B"),
      newPlayer("Hist C"), newPlayer("Hist D")]
    addSession(5, roster)
    check stats(database, communityId, roster[0]).get["history"].len == 2
    skipRoundZero(roster[0])
    let afterSkip = stats(database, communityId, roster[0]).get["history"]
    check afterSkip.len == 1
    check afterSkip[0]["gameRef"].getStr() == "1-0"
    # A draft session has no approved_at, so its score is not a result yet.
    let draft = database.queryOne(
      """insert into session.sessions
           (community_id, title, session_date, status, source)
         values ($1::uuid, 'Draft night', $2::date, 'draft', 'generator')
         returning id""",
      @[textParam(communityId), textParam(asOf)]).get.get("id")
    for player in roster:
      discard database.execUpdate(
        """insert into session.participants
             (community_id, session_id, player_id)
           values ($1::uuid, $2::uuid, $3::uuid)""",
        @[textParam(communityId), textParam(draft), textParam(player)])
    discard database.execUpdate(
      """insert into session.games
           (community_id, session_id, round_no, court_no, score_a, score_b,
            status, side_a1, side_a2, side_b1, side_b2)
         values ($1::uuid, $2::uuid, 3, 0, 21, 10, 'played',
                 $3::uuid, $4::uuid, $5::uuid, $6::uuid)""",
      @[textParam(communityId), textParam(draft), textParam(roster[0]),
        textParam(roster[1]), textParam(roster[2]), textParam(roster[3])])
    check stats(database, communityId, roster[0]).get["history"].len == 1

  test "a skipped player is not an opponent and loses that game":
    let roster = @[newPlayer("Soc A"), newPlayer("Soc B"),
      newPlayer("Soc C"), newPlayer("Soc D")]
    addSession(6, roster)
    check socialCount(stats(database, communityId,
      roster[0]).get["topOpponents"], "Soc C") == 2
    skipRoundZero(roster[2])
    let first = stats(database, communityId, roster[0]).get
    # Their own games stay: only the skipped player sat that one out.
    check first["history"].len == 2
    check socialCount(first["topPartners"], "Soc B") == 2
    # The skipped opponent was not on the other side of that game.
    check socialCount(first["topOpponents"], "Soc C") == 1
    check socialCount(first["topOpponents"], "Soc D") == 2
    let partner = stats(database, communityId, roster[1]).get
    check socialCount(partner["topOpponents"], "Soc C") == 1
    check stats(database, communityId, roster[2]).get["history"].len == 1

  test "a skipped partner does not count":
    let roster = @[newPlayer("Soc E"), newPlayer("Soc F"),
      newPlayer("Soc G"), newPlayer("Soc H")]
    addSession(7, roster)
    check socialCount(stats(database, communityId,
      roster[0]).get["topPartners"], "Soc F") == 2
    skipRoundZero(roster[1])
    let first = stats(database, communityId, roster[0]).get
    check first["history"].len == 2
    check socialCount(first["topPartners"], "Soc F") == 1
    check stats(database, communityId, roster[1]).get["history"].len == 1

  test "a player on side B sees their partner and their opponents":
    let roster = @[newPlayer("Soc I"), newPlayer("Soc J"),
      newPlayer("Soc K"), newPlayer("Soc L")]
    addSession(8, roster)
    # The partner used to be derived from side A only, so a side-B player had an
    # empty partner list even though the games were theirs.
    let sideB = stats(database, communityId, roster[2]).get
    check socialCount(sideB["topPartners"], "Soc L") == 2
    check socialCount(sideB["topOpponents"], "Soc I") == 2

  test "the session list is capped at the newest hundred":
    let player = newPlayer("List Guy")
    for age in 0 ..< 101:
      addEmptySession(player, age)
    let sessions = stats(database, communityId, player).get["sessions"]
    check sessions.len == 100
    for index in 1 ..< sessions.len:
      check sessions[index - 1]["date"].getStr() >=
        sessions[index]["date"].getStr()
