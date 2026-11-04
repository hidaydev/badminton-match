import std/[json, options, os, strutils, unittest]
import db/db
import ../../read
import ../../domain/rating

var
  database: Db
  communityId: string
  players: seq[string]

proc dsn(): string = getEnv("MAJADU_PG_DSN")

proc params(): RatingParams =
  RatingParams(sessionBase: 250, scoreTarget: 21, opponentClampLow: 0.5,
    opponentClampHigh: 1.5, windowWeeks: 12, bestN: 10, thinEvidenceN: 3)

proc cleanup() =
  for statement in [
    """delete from rating.snapshots where community_id in
         (select id from platform.community where slug = 'read-club')""",
    """delete from rating.deltas where community_id in
         (select id from platform.community where slug = 'read-club')""",
    """delete from rating.events where community_id in
         (select id from platform.community where slug = 'read-club')""",
    """delete from rating.player_state where community_id in
         (select id from platform.community where slug = 'read-club')""",
    """delete from player.players where community_id in
         (select id from platform.community where slug = 'read-club')""",
    "delete from platform.community where slug = 'read-club'"]:
    discard database.execUpdate(statement)

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
  # 40 events: 30 inside the window and 10 older than it.
  for eventIndex in 0 ..< 40:
    let age = if eventIndex < 10: 200 else: eventIndex
    let eventId = database.queryOne(
      """insert into rating.events (community_id, local_date, event_type)
         values ($1::uuid, current_date - $2::int, 'session') returning id""",
      @[textParam(communityId), intParam(age.int64)]).get.get("id")
    for playerIndex in 0 ..< 4:
      let player = players[(eventIndex * 4 + playerIndex) mod players.len]
      discard database.execUpdate(
        """insert into rating.deltas
             (community_id, event_id, side, player_id, delta)
           values ($1::uuid, $2::uuid, $3, $4::uuid, $5)
           on conflict (event_id, side, player_id) do nothing""",
        @[textParam(communityId), textParam(eventId),
          textParam(if playerIndex mod 2 == 0: "a" else: "b"),
          textParam(player), intParam(100 + eventIndex)])
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
    let rows = board(database, communityId, "2026-11-04", params(),
      200)
    check rows.len == 200
    for index in 1 ..< rows.len:
      check rows[index - 1].points >= rows[index].points
    # A player whose only deltas are older than the window scores nothing.
    let oldest = database.queryOne(
      """select d.player_id from rating.deltas d
         join rating.events e on e.id = d.event_id
         where d.community_id = $1::uuid and e.local_date <= current_date - 190
         limit 1""", @[textParam(communityId)])
    if oldest.isSome:
      let points = database.queryOne(
        """select coalesce(sum(delta), 0)::int as points from rating.deltas d
           join rating.events e on e.id = d.event_id
           where d.community_id = $1::uuid and d.player_id = $2::uuid
             and e.local_date > current_date - 84""",
        @[textParam(communityId), textParam(oldest.get.get("player_id"))])
      let entry = boardEntry(database, communityId,
        oldest.get.get("player_id"), "2026-11-04", params(), 200)
      check entry.isSome
      check entry.get.points == parseInt(points.get.get("points"))

  test "the best N entries are summed, not every entry":
    let heavy = players[0]
    for extra in 0 ..< 15:
      let eventId = database.queryOne(
        """insert into rating.events (community_id, local_date, event_type)
           values ($1::uuid, current_date - 1, 'session') returning id""",
        @[textParam(communityId)]).get.get("id")
      discard database.execUpdate(
        """insert into rating.deltas
             (community_id, event_id, side, player_id, delta)
           values ($1::uuid, $2::uuid, 'a', $3::uuid, $4)""",
        @[textParam(communityId), textParam(eventId), textParam(heavy),
          intParam((1000 + extra).int64)])
    let expected = database.queryOne(
      """select coalesce(sum(delta), 0)::int as points from (
           select delta from rating.deltas d
           join rating.events e on e.id = d.event_id
           where d.community_id = $1::uuid and d.player_id = $2::uuid
             and e.local_date > current_date - 84
           order by delta desc limit 10) best""",
      @[textParam(communityId), textParam(heavy)])
    let entry = boardEntry(database, communityId, heavy, "2026-11-04",
      params(), 200)
    check entry.isSome
    check entry.get.points == parseInt(expected.get.get("points"))
    check rankOf(database, communityId, heavy, "2026-11-04", params(), 200) == 1

  test "a snapshot matches the board on the same day":
    let rows = board(database, communityId, "2026-11-04", params(), 200)
    check writeSnapshot(database, communityId, "2026-11-04", rows) == rows.len
    check writeSnapshot(database, communityId, "2026-11-04", rows) == rows.len
    let snapshot = snapshotRows(database, communityId, "2026-11-04")
    check snapshot.len == rows.len
    for index in 0 ..< rows.len:
      check snapshot[index].playerId == rows[index].playerId
      check snapshot[index].points == rows[index].points

  test "stats and unknown players":
    let found = stats(database, communityId, players[0])
    check found.isSome
    check found.get["games"].getInt() == 5
    check stats(database, communityId,
      "00000000-0000-0000-0000-000000000000").isNone
