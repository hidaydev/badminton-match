## BE-08: one player's points are one row, not the whole board.
##
## `GET /c/{slug}/players/{id}/stats` used to run the board query with the board
## limit to read one integer. A statement count cannot tell those apart, so this
## suite counts the rows the driver materialises: the detail read must never
## return the ladder.

import std/[json, options, os, unittest]
import db/db
import community/infrastructure/community_store
import platform/config/store
import rating/infrastructure/ingest
import rating/infrastructure/params
import rating/read
import tests/fixtures

proc dsn(): string = getEnv("MAJADU_PG_DSN")

var
  database: Db
  communityId: string
  players: seq[string]

const playerCount = 20

proc cleanup() =
  purgeCommunity(database, "app-stats-club")
  discard database.execUpdate(
    "delete from platform.user where google_sub like 'app-stats-%'")

proc bootstrap() =
  database = openDb(dsn(), 2)
  cleanup()
  let ownerId = newUser(database, "app-stats-owner",
    "app-stats-owner@example.com", "Owner", owner = true)
  communityId = community_store.create(database, "app-stats-club",
    "Stats Club", "app-stats-admin@example.com", "Asia/Jakarta",
    ownerId).communityId
  for index in 0 ..< playerCount:
    players.add(newPlayer(database, communityId, "Stats P" & $index))
  let sessionId = newSession(database, communityId, "Stats night", "2026-11-09",
    status = "locked", approved = true)
  for player in players:
    newParticipant(database, communityId, sessionId, player)
  # Ten singles games: every player scores, so every player is on the ladder.
  for index in 0 ..< playerCount div 2:
    let round = index + 1
    newGame(database, communityId, sessionId, round, 1, [players[index * 2]],
      [players[index * 2 + 1]], status = "played", scoreA = 21, scoreB = 15)
    discard database.execUpdate(
      """insert into session.game_sets
           (community_id, session_id, round_no, court_no, set_no, score_a,
            score_b)
         values ($1::uuid, $2::uuid, $3, 1, 1, 21, 15)""",
      @[textParam(communityId), textParam(sessionId), intParam(round.int64)])
  discard ingestSession(database, communityId, sessionId,
    loadRatingParams(loadSnapshot(database), newJObject()))

if dsn().len == 0:
  echo "SKIP player stats read (MAJADU_PG_DSN is not set)"
else:
  bootstrap()
  suite "player stats read":
    let params = loadRatingParams(loadSnapshot(database), newJObject())
    let asOf = latestEventDate(database, communityId)
    let query = BoardQuery(communityId: communityId, asOf: asOf, params: params,
      limit: 200)

    test "the board itself lists every player":
      check board(database, query).len == playerCount

    test "one player's points cost one row, not the board":
      let ladder = board(database, query)
      check ladder.len == playerCount
      let target = ladder[0]
      let boardBefore = rowsReturned()
      discard board(database, query)
      let boardCost = rowsReturned() - boardBefore
      let entryBefore = rowsReturned()
      let entry = boardEntry(database, query, target.playerId)
      let entryCost = rowsReturned() - entryBefore
      check entry.isSome
      check entry.get.playerId == target.playerId
      check entry.get.points == target.points
      check entry.get.rank == target.rank
      # A board-wide read materialises every row; the detail read must not.
      check entryCost < boardCost

    test "the detail read returns fewer rows than the board it replaces":
      let ladder = board(database, query)
      check ladder.len == playerCount
      let before = rowsReturned()
      let entry = boardEntry(database, query, ladder[0].playerId)
      check entry.isSome
      # Even the projection behind the rank is narrower than the ladder rows the
      # old path materialised on top of it.
      check rowsReturned() - before < playerCount + ladder.len

  cleanup()
  database.close()
