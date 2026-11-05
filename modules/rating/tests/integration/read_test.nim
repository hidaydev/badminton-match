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

proc cleanup() =
  for statement in [
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
