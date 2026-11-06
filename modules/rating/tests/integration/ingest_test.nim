import std/[json, options, os, strutils, unittest]
import db/db
import ../../infrastructure/ingest
import ../../domain/rating

var
  database: Db
  communityId, sessionId: string
  players: array[4, string]

proc dsn(): string = getEnv("MAJADU_PG_DSN")

proc params(): RatingParams =
  RatingParams(sessionBase: 250, scoreTarget: 21, opponentClampLow: 0.5,
    opponentClampHigh: 1.5, windowWeeks: 12, bestN: 10, thinEvidenceN: 3)

proc cleanup() =
  for statement in [
    """delete from rating.events where community_id in
         (select id from platform.community where slug = 'ingest-club')""",
    """delete from rating.player_state where community_id in
         (select id from platform.community where slug = 'ingest-club')""",
    """delete from session.games where community_id in
         (select id from platform.community where slug = 'ingest-club')""",
    """delete from session.participants where community_id in
         (select id from platform.community where slug = 'ingest-club')""",
    """delete from session.sessions where community_id in
         (select id from platform.community where slug = 'ingest-club')""",
    """delete from player.players where community_id in
         (select id from platform.community where slug = 'ingest-club')""",
    "delete from platform.community where slug = 'ingest-club'"]:
    discard database.execUpdate(statement)

proc playerId(index: int): string =
  database.queryOne(
    """insert into player.players (community_id, canonical_name, gender)
       values ($1::uuid, $2, 'M') returning id""",
    @[textParam(communityId), textParam("Ingest " & $index)]).get.get("id")

proc seedSession(approved: bool, sessionDate = "2026-11-04",
                 scoreA = 21, scoreB = 15): string =
  let id = database.queryOne(
    """insert into session.sessions
         (community_id, title, session_date, status, source, version,
          approved_at, approved_by)
       values ($1::uuid, 'Ingest night', $3::date,
               case when $2 then 'locked' else 'draft' end, 'manual', 1,
               case when $2 then now() else null end, null)
       returning id""",
    @[textParam(communityId), boolParam(approved), textParam(sessionDate)])
    .get.get("id")
  for player in players:
    discard database.execUpdate(
      """insert into session.participants (community_id, session_id, player_id)
         values ($1::uuid, $2::uuid, $3::uuid)""",
      @[textParam(communityId), textParam(id), textParam(player)])
  discard database.execUpdate(
    """insert into session.games
         (community_id, session_id, round_no, court_no, score_a, score_b, status,
          side_a1, side_a2, side_b1, side_b2)
       values ($1::uuid, $2::uuid, 0, 0, $7::int, $8::int, 'played',
               $3::uuid, $4::uuid, $5::uuid, $6::uuid)""",
    @[textParam(communityId), textParam(id), textParam(players[0]),
      textParam(players[1]), textParam(players[2]), textParam(players[3]),
      intParam(scoreA.int64), intParam(scoreB.int64)])
  discard database.execUpdate(
    """insert into session.game_sets
         (community_id, session_id, round_no, court_no, set_no, score_a, score_b)
       values ($1::uuid, $2::uuid, 0, 0, 1, $3::int, $4::int)""",
    @[textParam(communityId), textParam(id), intParam(scoreA.int64),
      intParam(scoreB.int64)])
  id

proc state(player: string): tuple[games: int, wins: int, losses: int] =
  let row = database.queryOne(
    """select games_played, wins, losses from rating.player_state
       where community_id = $1::uuid and player_id = $2::uuid""",
    @[textParam(communityId), textParam(player)])
  if row.isNone:
    return (0, 0, 0)
  (parseInt(row.get.get("games_played")), parseInt(row.get.get("wins")),
   parseInt(row.get.get("losses")))

proc pointEntries(): int =
  let row = database.queryOne(
    """select coalesce(sum(point_entries), 0)::int as n from rating.events
       where community_id = $1::uuid""", @[textParam(communityId)])
  parseInt(row.get.get("n"))

proc eventCount(): int =
  let row = database.queryOne(
    """select count(*)::int as n from rating.events
       where community_id = $1::uuid""", @[textParam(communityId)])
  parseInt(row.get.get("n"))

proc setup() =
  database = openDb(dsn(), 1)
  cleanup()
  communityId = database.queryOne(
    """insert into platform.community (slug, name, timezone)
       values ('ingest-club', 'Ingest Club', 'Asia/Jakarta')
       returning id""").get.get("id")
  for index in 0 ..< 4:
    players[index] = playerId(index)

setup()

suite "rating ingest":
  test "a draft session is not a rating source":
    let draft = seedSession(approved = false)
    check ingestSession(database, communityId, draft, params()).events == 0
    check eventCount() == 0

  test "a locked session creates one event and counts every player":
    sessionId = seedSession(approved = true)
    let result = ingestSession(database, communityId, sessionId, params())
    check result.events == 1
    check result.deltas == 4
    check pointEntries() == 4
    check eventCount() == 1
    let winners = state(players[0])
    let losers = state(players[2])
    check winners.games == 1
    check winners.wins == 1
    check losers.losses == 1

  test "ingesting the same session twice adds nothing":
    check ingestSession(database, communityId, sessionId, params()).events == 0
    check eventCount() == 1
    check state(players[0]).games == 1

  test "a rebuild keeps the event id a client already holds":
    let before = database.queryOne(
      """select id::text as id from rating.events
         where community_id = $1::uuid and event_type = 'session'
           and source_id = $2::uuid""",
      @[textParam(communityId), textParam(sessionId)]).get.get("id")
    discard rebuild(database, communityId, params())
    let after = database.queryOne(
      """select id::text as id from rating.events
         where community_id = $1::uuid and event_type = 'session'
           and source_id = $2::uuid""",
      @[textParam(communityId), textParam(sessionId)]).get.get("id")
    check after == before

  test "an absent player is not counted and earns no game":
    discard database.execUpdate(
      """update session.participants set is_absent = true
         where community_id = $1::uuid and session_id = $2::uuid
           and player_id = $3::uuid""",
      @[textParam(communityId), textParam(sessionId), textParam(players[3])])
    discard ingestSession(database, communityId, sessionId, params())
    discard rebuild(database, communityId, params())
    check state(players[3]).games == 0
    check state(players[0]).games == 1
    check pointEntries() == 3
    discard database.execUpdate(
      """update session.participants set is_absent = false
         where community_id = $1::uuid and session_id = $2::uuid""",
      @[textParam(communityId), textParam(sessionId)])
    discard rebuild(database, communityId, params())

  test "revert then rebuild lands on the same numbers":
    let before = state(players[0])
    let removed = revertSource(database, communityId, sessionId)
    check removed == 4
    check eventCount() == 0
    check pointEntries() == 0
    let rebuilt = rebuild(database, communityId, params())
    check rebuilt.events == 1
    check eventCount() == 1

    let twice = rebuild(database, communityId, params())
    check twice.events == 1
    check state(players[0]) == before

  test "a skipped player is not counted in that game":
    discard database.execUpdate(
      """insert into session.game_skips
           (community_id, session_id, round_no, court_no, player_id)
         values ($1::uuid, $2::uuid, 0, 0, $3::uuid)""",
      @[textParam(communityId), textParam(sessionId), textParam(players[3])])
    discard rebuild(database, communityId, params())
    check state(players[3]).games == 0
    check state(players[0]).games == 1
    check pointEntries() == 3
    discard database.execUpdate(
      """delete from session.game_skips
         where community_id = $1::uuid and session_id = $2::uuid""",
      @[textParam(communityId), textParam(sessionId)])
    discard rebuild(database, communityId, params())
    check state(players[3]).games == 1

  test "a rebuild replays every approved session, and only once":
    let later = seedSession(approved = true, sessionDate = "2026-10-20",
      scoreA = 21, scoreB = 8)
    discard ingestSession(database, communityId, later, params())
    let earlier = seedSession(approved = true, sessionDate = "2026-10-10",
      scoreA = 21, scoreB = 20)
    discard ingestSession(database, communityId, earlier, params())
    var before: array[4, tuple[games: int, wins: int, losses: int]]
    for index in 0 ..< 4:
      before[index] = state(players[index])
    discard rebuild(database, communityId, params())
    for index in 0 ..< 4:
      check state(players[index]) == before[index]
    # The replay really covers both sources, not just the first one.
    check eventCount() == 3
