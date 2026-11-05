import std/[options, os, strutils, unittest]
import db/db
import ../../infrastructure/ledger

proc dsn(): string = getEnv("MAJADU_PG_DSN")

suite "rating ledger counters":
  var db: Db
  var communityId, first, second: string

  setup:
    if dsn().len == 0:
      raise newException(ValueError, "MAJADU_PG_DSN is required")
    db = openDb(dsn(), 1)
    discard db.execUpdate(
      """delete from rating.events where community_id in
           (select id from platform.community where slug = 'ledger-test')""")
    discard db.execUpdate(
      """delete from rating.sources where community_id in
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

  teardown:
    db.close()

  proc counters(player: string): tuple[games, wins, losses: int] =
    let row = db.queryOne(
      """select games_played, wins, losses from rating.player_state
         where community_id = $1::uuid and player_id = $2::uuid""",
      @[textParam(communityId), textParam(player)]).get
    (parseInt(row.get("games_played")), parseInt(row.get("wins")),
     parseInt(row.get("losses")))

  test "a side is counted once per listed player, repeats included":
    # A roster that names one player twice counts twice: the write folds the
    # repeat into a multiplicity instead of a second conflicting row.
    discard db.tx(proc(conn: DbConn): int =
      lockCommunity(conn, communityId)
      addState(conn, communityId, @[first, first], won = true)
      1)
    check counters(first) == (2, 2, 0)
    # A later game accumulates on top of the first one.
    discard db.tx(proc(conn: DbConn): int =
      addState(conn, communityId, @[first, second], won = false)
      1)
    check counters(first) == (3, 2, 1)
    check counters(second) == (1, 0, 1)

  test "an empty side writes nothing":
    discard db.tx(proc(conn: DbConn): int =
      addState(conn, communityId, @[], won = true)
      1)
    let row = db.queryOne(
      """select count(*)::int as n from rating.player_state
         where community_id = $1::uuid""", @[textParam(communityId)])
    check row.get.get("n") == "0"

  test "finalisation is read back from the source row":
    let sourceId = "11111111-1111-4111-8111-111111111111"
    discard db.execUpdate(
      """insert into rating.sources (community_id, source_id, kind, finalized)
         values ($1::uuid, $2::uuid, 'session', false)""",
      @[textParam(communityId), textParam(sourceId)])
    check db.tx(proc(conn: DbConn): bool =
      sourceFinalizedConn(conn, communityId, sourceId)) == false
    discard db.execUpdate(
      """update rating.sources set finalized = true
         where community_id = $1::uuid and source_id = $2::uuid""",
      @[textParam(communityId), textParam(sourceId)])
    check db.tx(proc(conn: DbConn): bool =
      sourceFinalizedConn(conn, communityId, sourceId))