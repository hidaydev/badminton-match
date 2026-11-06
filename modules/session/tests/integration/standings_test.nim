## Standings follow the v1 tally: a played game counts only when both sides
## still have a real participant, absent players never score, and the order is
## wins, then difference, then points for, then name.

import std/[json, options, os, unittest]
import db/db
import ../../standings

proc dsn(): string = getEnv("MAJADU_PG_DSN")

suite "session standings":
  var db: Db
  var communityId, sessionId: string
  var players: seq[string]

  setup:
    if dsn().len == 0:
      raise newException(ValueError, "MAJADU_PG_DSN is required")
    db = openDb(dsn(), 1)
    discard db.execUpdate(
      """delete from session.games where community_id in
           (select id from platform.community where slug = 'standings-test')""")
    discard db.execUpdate(
      """delete from session.participants where community_id in
           (select id from platform.community where slug = 'standings-test')""")
    discard db.execUpdate(
      """delete from session.sessions where community_id in
           (select id from platform.community where slug = 'standings-test')""")
    discard db.execUpdate(
      """delete from player.players where community_id in
           (select id from platform.community where slug = 'standings-test')""")
    discard db.execUpdate(
      "delete from platform.community where slug = 'standings-test'")
    communityId = db.queryOne(
      """insert into platform.community (slug, name, timezone)
         values ('standings-test', 'Standings Test', 'Asia/Jakarta') returning id"""
      ).get.get("id")
    sessionId = db.queryOne(
      """insert into session.sessions
           (community_id, title, session_date, start_time, slot_minutes, status, source)
         values ($1::uuid, 'Wednesday', '2026-11-04', '19:00', 30, 'locked', 'manual')
         returning id""", @[textParam(communityId)]).get.get("id")
    players = @[]
    for name in ["Alice", "Budi", "Candra", "Dewi", "Eka"]:
      players.add(db.queryOne(
        """insert into player.players (community_id, canonical_name)
           values ($1::uuid, $2) returning id""",
        @[textParam(communityId), textParam(name)]).get.get("id"))
      discard db.execUpdate(
        """insert into session.participants
             (community_id, session_id, player_id, is_absent)
           values ($1::uuid, $2::uuid, $3::uuid, $4)""",
        @[textParam(communityId), textParam(sessionId), textParam(players[^1]),
          boolParam(name == "Eka")])

  teardown:
    db.close()

  proc addGame(roundNo, courtNo: int, scoreA, scoreB: int, status: string,
               sideA1, sideA2, sideB1, sideB2: string) =
    discard db.execUpdate(
      """insert into session.games
           (community_id, session_id, round_no, court_no, score_a, score_b,
            status, side_a1, side_a2, side_b1, side_b2)
         values ($1::uuid, $2::uuid, $3, $4, $5, $6, $7, $8::uuid, $9::uuid,
                 $10::uuid, $11::uuid)""",
      @[textParam(communityId), textParam(sessionId), intParam(roundNo.int64),
        intParam(courtNo.int64), intParam(scoreA.int64), intParam(scoreB.int64),
        textParam(status),
        (if sideA1.len > 0: textParam(sideA1) else: nullParam()),
        (if sideA2.len > 0: textParam(sideA2) else: nullParam()),
        (if sideB1.len > 0: textParam(sideB1) else: nullParam()),
        (if sideB2.len > 0: textParam(sideB2) else: nullParam())])
    # The board reads the result from the sets; a played game needs its one set.
    if status == "played":
      discard db.execUpdate(
        """insert into session.game_sets
             (community_id, session_id, round_no, court_no, set_no, score_a, score_b)
           values ($1::uuid, $2::uuid, $3, $4, 1, $5, $6)""",
        @[textParam(communityId), textParam(sessionId), intParam(roundNo.int64),
          intParam(courtNo.int64), intParam(scoreA.int64), intParam(scoreB.int64)])

  test "tallies played games, drops absent-only sides and orders like v1":
    addGame(0, 0, 21, 18, "played", players[0], players[1], players[2], players[3])
    addGame(0, 1, 30, 25, "played", players[0], players[2], players[1], players[3])
    addGame(0, 2, 20, 15, "played", players[0], players[4], players[1], players[2])
    # Only the absent player on side A, so the whole game is dropped.
    addGame(0, 3, 10, 21, "played", players[4], "", players[2], players[3])
    # Cancelled games never count.
    addGame(1, 0, 30, 10, "cancelled", players[0], "", players[1], "")

    let board = compute(db, communityId, sessionId)
    check board.isSome
    let items = board.get["items"]
    check items.len == 4
    check board.get["title"].getStr() == "Wednesday"
    check board.get["date"].getStr() == "2026-11-04"

    check items[0]["name"].getStr() == "Alice"
    check items[0]["wins"].getInt() == 3
    check items[0]["losses"].getInt() == 0
    check items[0]["pointsFor"].getInt() == 71
    check items[0]["pointsAgainst"].getInt() == 58
    check items[0]["diff"].getInt() == 13

    check items[1]["name"].getStr() == "Candra"
    check items[1]["wins"].getInt() == 1
    check items[1]["diff"].getInt() == -3

    check items[2]["name"].getStr() == "Budi"
    check items[2]["wins"].getInt() == 1
    check items[2]["diff"].getInt() == -7

    check items[3]["name"].getStr() == "Dewi"
    check items[3]["wins"].getInt() == 0
    check items[3]["diff"].getInt() == -8

    var sawAbsent = false
    for item in items:
      if item["name"].getStr() == "Eka":
        sawAbsent = true
    check not sawAbsent

  test "a session without played games totals nothing":
    let board = compute(db, communityId, sessionId)
    check board.isSome
    check board.get["items"].len == 4
    for item in board.get["items"]:
      check item["wins"].getInt() == 0
      check item["losses"].getInt() == 0

  test "a session from another community is not found":
    check compute(db, communityId,
      "11111111-1111-1111-1111-111111111111").isNone

  test "a skipped player is left out of only that game":
    addGame(0, 0, 21, 18, "played", players[0], players[1], players[2], players[3])
    addGame(0, 1, 21, 18, "played", players[0], players[1], players[2], players[3])
    discard db.execUpdate(
      """insert into session.game_skips
           (community_id, session_id, round_no, court_no, player_id)
         values ($1::uuid, $2::uuid, 0, 0, $3::uuid)""",
      @[textParam(communityId), textParam(sessionId), textParam(players[2])])

    let items = compute(db, communityId, sessionId).get["items"]
    check items[0]["name"].getStr() == "Alice"
    check items[0]["wins"].getInt() == 2
    check items[1]["name"].getStr() == "Budi"
    check items[1]["wins"].getInt() == 2

    var candra = 0
    var dewi = 0
    for item in items:
      if item["name"].getStr() == "Candra": candra = item["losses"].getInt()
      if item["name"].getStr() == "Dewi": dewi = item["losses"].getInt()
    check candra == 1
    check dewi == 2

  test "a fully skipped side still gives the other side the result":
    addGame(0, 0, 18, 21, "played", players[0], players[1], players[2], players[3])
    for id in [players[0], players[1]]:
      discard db.execUpdate(
        """insert into session.game_skips
             (community_id, session_id, round_no, court_no, player_id)
           values ($1::uuid, $2::uuid, 0, 0, $3::uuid)""",
        @[textParam(communityId), textParam(sessionId), textParam(id)])

    let items = compute(db, communityId, sessionId).get["items"]
    var alice, candra, dewi: int
    for item in items:
      case item["name"].getStr()
      of "Alice": alice = item["losses"].getInt()
      of "Candra": candra = item["wins"].getInt()
      of "Dewi": dewi = item["wins"].getInt()
      else: discard
    check alice == 0
    check candra == 1
    check dewi == 1
