## BE-06 / BE-08: the session read lives in the application layer and costs a
## fixed number of statements.
##
## The delivery layer renders these rows and holds no SQL of its own. The
## statement counter proves the read does not grow with the number of games: one
## query per game is what made the member page and the public payload scale with
## the result set.

import std/[options, os, unittest]
import db/db
import session/application/detail
import tests/fixtures

proc dsn(): string = getEnv("MAJADU_PG_DSN")

var
  database: Db
  communityId: string
  playerIds: seq[string]

proc cleanup() =
  purgeCommunity(database, "app-detail-club")
  discard database.execUpdate(
    "delete from platform.user where google_sub like 'app-detail-%'")

proc bootstrap() =
  database = openDb(dsn(), 2)
  cleanup()
  let ownerId = newUser(database, "app-detail-owner",
    "app-detail-owner@example.com", "Owner", owner = true)
  communityId = newCommunity(database, "app-detail-club", "Detail Club")
  newMember(database, communityId, ownerId, "admin")
  for index in 0 ..< 4:
    playerIds.add(newPlayer(database, communityId, "Detail P" & $index))

proc sessionWithGames(title: string, games: int): string =
  result = newSession(database, communityId, title, "2026-11-09")
  for playerId in playerIds:
    newParticipant(database, communityId, result, playerId)
  for index in 0 ..< games:
    let roundNo = index div 2 + 1
    let courtNo = index mod 2 + 1
    newGame(database, communityId, result, roundNo, courtNo,
      [playerIds[0], playerIds[1]], [playerIds[2], playerIds[3]],
      status = "played", scoreA = 21, scoreB = 15)
    discard database.execUpdate(
      """insert into session.game_sets
           (community_id, session_id, round_no, court_no, set_no, score_a,
            score_b)
         values ($1::uuid, $2::uuid, $3, $4, 1, 21, 15)""",
      @[textParam(communityId), textParam(result), intParam(roundNo.int64),
        intParam(courtNo.int64)])

proc statementsFor(sessionId: string): int =
  let before = statementsIssued()
  let loaded = load(database, communityId, sessionId)
  check loaded.isSome
  statementsIssued() - before

if dsn().len == 0:
  echo "SKIP session detail (MAJADU_PG_DSN is not set)"
else:
  bootstrap()
  suite "session detail application read":
    test "a session with two games and a session with twenty cost the same":
      let small = sessionWithGames("Small", 2)
      let large = sessionWithGames("Large", 20)
      let smallCost = statementsFor(small)
      let largeCost = statementsFor(large)
      # header, participants, games, sets: four, whatever the game count.
      check smallCost == 4
      check largeCost == 4
      check largeCost == smallCost

    test "every game carries its own sets":
      let sessionId = sessionWithGames("Sets", 3)
      let loaded = load(database, communityId, sessionId)
      check loaded.isSome
      let detail = loaded.get
      check detail.games.len == 3
      for game in detail.games:
        check game.sets.len == 1
        check game.sets[0].a == 21
        check game.sets[0].b == 15

    test "one game is one statement and names only that game":
      let sessionId = sessionWithGames("One", 2)
      let before = statementsIssued()
      let game = loadGame(database, communityId, sessionId, 1, 2)
      check game.isSome
      check statementsIssued() - before == 1
      check game.get.roundNo == 1
      check game.get.courtNo == 2
      check game.get.sets.len == 1

    test "an unknown session is none, not an empty read":
      check load(database, communityId,
        "00000000-0000-0000-0000-000000000000").isNone
      check versionOf(database, communityId,
        "00000000-0000-0000-0000-000000000000") == 0

    test "an approval stamp with a draft status is not approved":
      let sessionId = newSession(database, communityId, "Draft",
        "2026-11-09")
      discard database.execUpdate(
        """update session.sessions set approved_at = now()
           where community_id = $1::uuid and id = $2::uuid""",
        @[textParam(communityId), textParam(sessionId)])
      check not isApproved(database, communityId, sessionId)
      let approved = newSession(database, communityId, "Locked", "2026-11-09",
        status = "locked", approved = true)
      check isApproved(database, communityId, approved)

  cleanup()
  database.close()
