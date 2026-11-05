import std/[options, os, strutils, unittest]
import db/db
import ../../infrastructure/ledger

proc dsn(): string = getEnv("MAJADU_PG_DSN")

suite "rating ledger writes":
  var db: Db
  var communityId, eventId, first, second: string

  setup:
    if dsn().len == 0:
      raise newException(ValueError, "MAJADU_PG_DSN is required")
    db = openDb(dsn(), 1)
    discard db.execUpdate(
      """delete from rating.deltas where community_id in
           (select id from platform.community where slug = 'ledger-test')""")
    discard db.execUpdate(
      """delete from rating.events where community_id in
           (select id from platform.community where slug = 'ledger-test')""")
    discard db.execUpdate(
      """delete from rating.player_state where community_id in
           (select id from platform.community where slug = 'ledger-test')""")
    discard db.execUpdate(
      """delete from player.players where community_id in
           (select id from platform.community where slug = 'ledger-test')""")
    discard db.execUpdate(
      "delete from platform.community where slug = 'ledger-test'")
    communityId = db.queryOne(
      """insert into platform.community (slug, name, timezone)
         values ('ledger-test', 'Ledger Test', 'Asia/Jakarta') returning id""")
      .get.get("id")
    for name in ["One", "Two"]:
      discard db.execUpdate(
        """insert into player.players (community_id, canonical_name)
           values ($1::uuid, $2)""",
        @[textParam(communityId), textParam(name)])
    let players = db.query(
      """select id from player.players
         where community_id = $1::uuid order by canonical_name""",
      @[textParam(communityId)])
    first = ""
    second = ""
    for row in players:
      if first.len == 0: first = row.get("id") else: second = row.get("id")
    eventId = db.queryOne(
      """insert into rating.events (community_id, local_date, event_type)
         values ($1::uuid, '2026-11-01', 'session') returning id""",
      @[textParam(communityId)]).get.get("id")

  teardown:
    db.close()

  proc deltaCount(): int =
    parseInt(db.queryOne(
      """select count(*)::int as n from rating.deltas where event_id = $1::uuid""",
      @[textParam(eventId)]).get.get("n"))

  test "one statement writes a whole event, and a replay adds no second row":
    let rows = @[
      DeltaRow(side: "a", playerId: first, gameKey: "0-0", delta: 10),
      DeltaRow(side: "a", playerId: second, gameKey: "0-0", delta: 10),
      DeltaRow(side: "b", playerId: first, gameKey: "0-0", delta: -4),
    ]
    discard db.tx(proc(conn: DbConn): int =
      writeDeltas(conn, communityId, eventId, rows)
      1)
    check deltaCount() == 3
    # Replaying the same event must not double the ledger.
    discard db.tx(proc(conn: DbConn): int =
      writeDeltas(conn, communityId, eventId, rows)
      1)
    check deltaCount() == 3

  test "a game key carrying a comma, a brace or a quote survives the batch":
    # The batch passes arrays as text literals; a match key is free text, so the
    # quoting has to hold or one key would split the literal into two players.
    let odd = "r1,\"c2\"{x}"
    discard db.tx(proc(conn: DbConn): int =
      writeDeltas(conn, communityId, eventId, @[
        DeltaRow(side: "a", playerId: first, gameKey: odd, delta: 7),
      ])
      1)
    let row = db.queryOne(
      """select game_key, delta from rating.deltas
         where event_id = $1::uuid and player_id = $2::uuid and side = 'a'""",
      @[textParam(eventId), textParam(first)])
    check row.get.get("game_key") == odd
    check row.get.get("delta") == "7"

  test "a roster that names one player twice counts twice":
    discard db.tx(proc(conn: DbConn): int =
      addState(conn, communityId, @[first, first], 5, true)
      1)
    var state = db.queryOne(
      """select rating, games_played, wins, losses from rating.player_state
         where community_id = $1::uuid and player_id = $2::uuid""",
      @[textParam(communityId), textParam(first)]).get
    check state.get("rating") == "10"
    check state.get("games_played") == "2"
    check state.get("wins") == "2"
    check state.get("losses") == "0"
    # The second write accumulates on top of the first.
    discard db.tx(proc(conn: DbConn): int =
      addState(conn, communityId, @[first], -3, false)
      1)
    state = db.queryOne(
      """select rating, games_played, wins, losses from rating.player_state
         where community_id = $1::uuid and player_id = $2::uuid""",
      @[textParam(communityId), textParam(first)]).get
    check state.get("rating") == "7"
    check state.get("games_played") == "3"
    check state.get("losses") == "1"
    # An empty side is a no-op, not an error.
    discard db.tx(proc(conn: DbConn): int =
      addState(conn, communityId, @[], 1, true)
      1)
    check state.get("rating") == "7"