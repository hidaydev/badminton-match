import std/[json, options, os, strutils, unittest]
import db/db
import ../swap

proc dsn(): string = getEnv("MAJADU_PG_DSN")

if dsn().len == 0:
  echo "session swap suite: skipped (MAJADU_PG_DSN is not set)"
  quit(0)

const slug = "swap-club"

type
  Game = object
    ## `sides` is A1, A2, B1, B2; a NULL score is a game not played yet.
    sides: array[4, string]
    scoreA: Option[int]
    scoreB: Option[int]
    status: string

var
  database: Db
  communityId: string
  players: array[8, string]

proc cleanup() =
  ## FK-safe order for every row this suite may leave behind.
  for statement in [
    """delete from rating.deltas where community_id in
         (select id from platform.community where slug = 'swap-club')""",
    """delete from rating.events where community_id in
         (select id from platform.community where slug = 'swap-club')""",
    """delete from rating.player_state where community_id in
         (select id from platform.community where slug = 'swap-club')""",
    """delete from rating.snapshots where community_id in
         (select id from platform.community where slug = 'swap-club')""",
    """delete from tournament.matches where community_id in
         (select id from platform.community where slug = 'swap-club')""",
    """delete from tournament.pairs where community_id in
         (select id from platform.community where slug = 'swap-club')""",
    """delete from tournament.tournaments where community_id in
         (select id from platform.community where slug = 'swap-club')""",
    """delete from achievement.earned where community_id in
         (select id from platform.community where slug = 'swap-club')""",
    """delete from session.games where community_id in
         (select id from platform.community where slug = 'swap-club')""",
    """delete from session.participants where community_id in
         (select id from platform.community where slug = 'swap-club')""",
    """delete from session.courts where community_id in
         (select id from platform.community where slug = 'swap-club')""",
    """delete from session.links where community_id in
         (select id from platform.community where slug = 'swap-club')""",
    """delete from session.sessions where community_id in
         (select id from platform.community where slug = 'swap-club')""",
    """delete from player.claims where community_id in
         (select id from platform.community where slug = 'swap-club')""",
    """delete from player.merge_log where community_id in
         (select id from platform.community where slug = 'swap-club')""",
    """delete from player.players where community_id in
         (select id from platform.community where slug = 'swap-club')""",
    """delete from community.membership where community_id in
         (select id from platform.community where slug = 'swap-club')""",
    "delete from platform.community where slug = 'swap-club'"]:
    discard database.execUpdate(statement)

proc addPlayer(index: int): string =
  database.queryOne(
    """insert into player.players (community_id, canonical_name, gender)
       values ($1::uuid, $2, 'M') returning id""",
    @[textParam(communityId), textParam("Swap " & align($index, 2))]).get.get("id")

proc addSession(status = "draft"): string =
  database.queryOne(
    """insert into session.sessions
         (community_id, title, session_date, status, source)
       values ($1::uuid, 'Swap night', '2026-11-04', $2, 'manual')
       returning id""",
    @[textParam(communityId), textParam(status)]).get.get("id")

proc addParticipant(sessionId, playerId: string) =
  discard database.execUpdate(
    """insert into session.participants (community_id, session_id, player_id)
       values ($1::uuid, $2::uuid, $3::uuid)""",
    @[textParam(communityId), textParam(sessionId), textParam(playerId)])

proc addGame(sessionId: string, round, court: int, game: Game) =
  discard database.execUpdate(
    """insert into session.games
         (community_id, session_id, round_no, court_no, side_a1, side_a2,
          side_b1, side_b2, score_a, score_b, status)
       values ($1::uuid, $2::uuid, $3, $4,
               nullif($5, '')::uuid, nullif($6, '')::uuid,
               nullif($7, '')::uuid, nullif($8, '')::uuid,
               $9, $10, $11)""",
    @[textParam(communityId), textParam(sessionId),
      intParam(round.int64), intParam(court.int64),
      textParam(game.sides[0]), textParam(game.sides[1]),
      textParam(game.sides[2]), textParam(game.sides[3]),
      if game.scoreA.isSome: intParam(game.scoreA.get.int64) else: nullParam(),
      if game.scoreB.isSome: intParam(game.scoreB.get.int64) else: nullParam(),
      textParam(game.status)])

proc readGame(sessionId: string, round, court: int): Game =
  let row = database.queryOne(
    """select coalesce(side_a1::text, '') as a1,
              coalesce(side_a2::text, '') as a2,
              coalesce(side_b1::text, '') as b1,
              coalesce(side_b2::text, '') as b2,
              score_a, score_b, status
       from session.games
       where community_id = $1::uuid and session_id = $2::uuid
         and round_no = $3 and court_no = $4""",
    @[textParam(communityId), textParam(sessionId),
      intParam(round.int64), intParam(court.int64)]).get
  result.sides = [row.get("a1"), row.get("a2"), row.get("b1"), row.get("b2")]
  if row["score_a"].isSome: result.scoreA = some(parseInt(row.get("score_a")))
  if row["score_b"].isSome: result.scoreB = some(parseInt(row.get("score_b")))
  result.status = row.get("status")

proc gameVersion(sessionId: string, round, court: int): int =
  parseInt(database.queryOne(
    """select version from session.games
       where community_id = $1::uuid and session_id = $2::uuid
         and round_no = $3 and court_no = $4""",
    @[textParam(communityId), textParam(sessionId),
      intParam(round.int64), intParam(court.int64)]).get.get("version"))

proc sessionVersion(sessionId: string): int =
  parseInt(database.queryOne(
    """select version from session.sessions
       where community_id = $1::uuid and id = $2::uuid""",
    @[textParam(communityId), textParam(sessionId)]).get.get("version"))

suite "session swap":
  var sessionId: string

  setup:
    database = openDb(dsn(), 1)
    cleanup()
    communityId = database.queryOne(
      """insert into platform.community (slug, name, timezone)
         values ('swap-club', 'Swap Club', 'Asia/Jakarta') returning id""").get.get("id")
    for index in 0 ..< players.len:
      players[index] = addPlayer(index)
    sessionId = addSession()
    for player in players:
      addParticipant(sessionId, player)
    # (0,0) and (1,0) both start full: p0-p3 at round 0, p4-p7 at round 1.
    addGame(sessionId, 0, 0, Game(sides: [players[0], players[1],
      players[2], players[3]], status: "scheduled"))
    addGame(sessionId, 1, 0, Game(sides: [players[4], players[5],
      players[6], players[7]], status: "scheduled"))

  teardown:
    database.close()

  test "a player swap inside one game exchanges the two slots":
    let patch = parseSwap(%*{"type": "player",
      "a": {"slot": 0, "court": 0, "team": "A", "position": 0},
      "b": {"slot": 0, "court": 0, "team": "A", "position": 1}})
    let outcome = swapMembers(database, communityId, sessionId, 1, patch)
    check outcome.status == swOk
    check outcome.version == 2
    check outcome.sessionStatus == "draft"
    check readGame(sessionId, 0, 0).sides ==
      [players[1], players[0], players[2], players[3]]
    check gameVersion(sessionId, 0, 0) == 2
    check sessionVersion(sessionId) == 2

  test "a player swap across games moves one id into each game":
    let patch = parseSwap(%*{"type": "player",
      "a": {"slot": 0, "court": 0, "team": "A", "position": 0},
      "b": {"slot": 1, "court": 0, "team": "B", "position": 1}})
    check swapMembers(database, communityId, sessionId, 1, patch).status == swOk
    check readGame(sessionId, 0, 0).sides ==
      [players[7], players[1], players[2], players[3]]
    check readGame(sessionId, 1, 0).sides ==
      [players[4], players[5], players[6], players[0]]

  test "a team swap across games moves the pair on one side letter":
    let patch = parseSwap(%*{"type": "team",
      "a": {"slot": 0, "court": 0, "team": "A", "position": 0},
      "b": {"slot": 1, "court": 0, "team": "A", "position": 1}})
    check swapMembers(database, communityId, sessionId, 1, patch).status == swOk
    check readGame(sessionId, 0, 0).sides ==
      [players[4], players[5], players[2], players[3]]
    check readGame(sessionId, 1, 0).sides ==
      [players[0], players[1], players[6], players[7]]

  test "a team swap inside one game exchanges the two sides":
    let patch = parseSwap(%*{"type": "team",
      "a": {"slot": 0, "court": 0, "team": "A", "position": 0},
      "b": {"slot": 0, "court": 0, "team": "B", "position": 0}})
    check swapMembers(database, communityId, sessionId, 1, patch).status == swOk
    check readGame(sessionId, 0, 0).sides ==
      [players[2], players[3], players[0], players[1]]

  test "a slot swap moves both games, score and status included":
    discard database.execUpdate(
      """update session.games set score_a = 21, score_b = 15, status = 'played'
         where community_id = $1::uuid and session_id = $2::uuid
           and round_no = 0 and court_no = 0""",
      @[textParam(communityId), textParam(sessionId)])
    let patch = parseSwap(%*{"type": "slot",
      "a": {"slot": 0, "court": 0},
      "b": {"slot": 1, "court": 0}})
    let outcome = swapMembers(database, communityId, sessionId, 1, patch)
    check outcome.status == swOk
    let first = readGame(sessionId, 0, 0)
    check first.sides == [players[4], players[5], players[6], players[7]]
    check first.scoreA.isNone and first.scoreB.isNone
    check first.status == "scheduled"
    let second = readGame(sessionId, 1, 0)
    check second.sides == [players[0], players[1], players[2], players[3]]
    check second.scoreA == some(21)
    check second.scoreB == some(15)
    check second.status == "played"

  test "a stale version changes nothing":
    let patch = parseSwap(%*{"type": "player",
      "a": {"slot": 0, "court": 0, "team": "A", "position": 0},
      "b": {"slot": 0, "court": 0, "team": "B", "position": 0}})
    let outcome = swapMembers(database, communityId, sessionId, 7, patch)
    check outcome.status == swStale
    check sessionVersion(sessionId) == 1
    check readGame(sessionId, 0, 0).sides ==
      [players[0], players[1], players[2], players[3]]
    check gameVersion(sessionId, 0, 0) == 1

  test "a locked session is rejected and an unknown one is not found":
    discard database.execUpdate(
      """update session.sessions set status = 'locked'
         where community_id = $1::uuid and id = $2::uuid""",
      @[textParam(communityId), textParam(sessionId)])
    let patch = parseSwap(%*{"type": "player",
      "a": {"slot": 0, "court": 0, "team": "A", "position": 0},
      "b": {"slot": 0, "court": 0, "team": "B", "position": 0}})
    check swapMembers(database, communityId, sessionId, 1, patch).status == swLocked
    check readGame(sessionId, 0, 0).sides ==
      [players[0], players[1], players[2], players[3]]
    check sessionVersion(sessionId) == 1
    check swapMembers(database, communityId,
      "11111111-1111-1111-1111-111111111111", 1, patch).status == swNotFound

  test "invalid targets are rejected without touching a row":
    let before = [readGame(sessionId, 0, 0), readGame(sessionId, 1, 0)]
    let bodies = @[
      %*{"type": "bogus", "a": {"slot": 0, "court": 0, "team": "A", "position": 0},
         "b": {"slot": 1, "court": 0, "team": "A", "position": 0}},
      %*{"a": {"slot": 0, "court": 0, "team": "A", "position": 0},
         "b": {"slot": 1, "court": 0, "team": "A", "position": 0}},
      %*{"type": "slot", "a": {"slot": 0, "court": 0}, "b": {"slot": 0, "court": 0}},
      %*{"type": "player", "a": {"slot": 0, "court": 0, "team": "A", "position": 0},
         "b": {"slot": 0, "court": 0, "team": "A", "position": 0}},
      %*{"type": "player", "a": {"slot": 0, "court": 0, "team": "C", "position": 0},
         "b": {"slot": 1, "court": 0, "team": "A", "position": 0}},
      %*{"type": "player", "a": {"slot": 0, "court": 0, "team": "A", "position": 2},
         "b": {"slot": 1, "court": 0, "team": "A", "position": 0}},
      %*{"type": "player", "a": {"slot": -1, "court": 0, "team": "A", "position": 0},
         "b": {"slot": 1, "court": 0, "team": "A", "position": 0}},
      %*{"type": "team", "a": {"slot": 0, "court": 0, "team": "A", "position": 0},
         "b": {"slot": 1, "court": 0, "team": "B", "position": 0}},
      %*{"type": "team", "a": {"slot": 0, "court": 0, "team": "A", "position": 0},
         "b": {"slot": 0, "court": 0, "team": "A", "position": 1}},
      %*{"type": "player", "a": {"slot": 0, "court": 0, "team": "A", "position": 0},
         "b": {"slot": 5, "court": 0, "team": "A", "position": 0}},
      %*{"type": "player", "a": [], "b": {"slot": 1, "court": 0,
         "team": "A", "position": 0}}]
    for body in bodies:
      let outcome = swapMembers(database, communityId, sessionId, 1, parseSwap(body))
      checkpoint("body " & $body)
      check outcome.status == swInvalid
    check sessionVersion(sessionId) == 1
    check readGame(sessionId, 0, 0).sides == before[0].sides
    check readGame(sessionId, 1, 0).sides == before[1].sides

  test "a swap that duplicates one player in a game rolls both rows back":
    # p0 sits in round 1 as well, so moving p0 there would break the distinct
    # sides CHECK; the transaction must leave round 0 untouched.
    discard database.execUpdate(
      """update session.games set side_b1 = $5::uuid
         where community_id = $1::uuid and session_id = $2::uuid
           and round_no = $3 and court_no = $4""",
      @[textParam(communityId), textParam(sessionId), intParam(1),
        intParam(0), textParam(players[0])])
    let patch = parseSwap(%*{"type": "player",
      "a": {"slot": 0, "court": 0, "team": "A", "position": 0},
      "b": {"slot": 1, "court": 0, "team": "A", "position": 0}})
    let outcome = swapMembers(database, communityId, sessionId, 1, patch)
    check outcome.status == swInvalid
    check sessionVersion(sessionId) == 1
    check readGame(sessionId, 0, 0).sides ==
      [players[0], players[1], players[2], players[3]]
    check readGame(sessionId, 1, 0).sides ==
      [players[4], players[5], players[0], players[7]]
