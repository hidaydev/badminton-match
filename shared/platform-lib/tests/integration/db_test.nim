import std/[atomics, monotimes, options, os, strutils, times, unittest]
import ../../db/db
import ../../waiters

proc dsn(): string =
  getEnv("MAJADU_PG_DSN")

type
  HolderArgs = object
    db: Db
    started: ptr Atomic[int]
    released: ptr Atomic[int]

proc holdConnection(args: HolderArgs) {.thread.} =
  ## Keeps the only connection checked out until the caller says its own
  ## acquire timeout has expired. The hold is tied to that observation instead
  ## of a guessed interval, so it is never too short under load (SQ-26).
  {.cast(gcsafe).}:
    args.db.tx(proc(conn: DbConn) =
      args.started[].store(1, moRelaxed)
      waitUntil(proc(): bool = args.released[].load(moRelaxed) == 1,
        proc(): string = "the caller never released the held connection",
        timeoutMs = 30000))

suite "database layer":
  var db: Db

  setup:
    if dsn().len == 0:
      raise newException(ValueError, "MAJADU_PG_DSN is required")
    db = openDb(dsn(), 2)
    discard db.execUpdate("drop table if exists t004_probe")
    discard db.execUpdate(
      "create table t004_probe (id int primary key, note text, doc jsonb)")

  teardown:
    discard db.execUpdate("drop table if exists t004_probe")
    db.close()

  test "pool size matches workerThreads":
    check db.size == 2

  test "binds text, keeps NULL as NULL":
    check db.execUpdate(
      "insert into t004_probe (id, note, doc) values ($1, $2, $3::jsonb)",
      @[intParam(1), nullParam(), textParam("""{"a":1}""")]) == 1
    let row = db.queryOne(
      "select note, id from t004_probe where id = $1", @[intParam(1)]).get
    check row["note"].isNone
    check row.get("id") == "1"

  test "keeps every bound string distinct":
    # Regression: the cstring pointers must outlive PQexecParams, otherwise all
    # parameters alias the last temporary and every column receives one value.
    discard db.execUpdate(
      "insert into t004_probe (id, note) values ($1, $2)",
      @[intParam(9), textParam("alpha")])
    discard db.execUpdate(
      "insert into t004_probe (id, note) values ($1, $2)",
      @[intParam(10), textParam("beta")])
    let row = db.queryOne(
      "select (select note from t004_probe where id = 9) as a," &
      " (select note from t004_probe where id = 10) as b," &
      " (select count(distinct note) from t004_probe) as distinct_notes").get
    check row.get("a") == "alpha"
    check row.get("b") == "beta"
    check row.get("distinct_notes") == "2"

  test "jsonb question mark operator is untouched":
    discard db.execUpdate(
      "insert into t004_probe (id, doc) values ($1, $2::jsonb)",
      @[intParam(2), textParam("""{"a":1}""")])
    let row = db.queryOne(
      """select doc ? 'a' as has_a, doc ? 'b' as has_b
         from t004_probe where id = $1""", @[intParam(2)]).get
    check row.get("has_a") == "t"
    check row.get("has_b") == "f"

  test "maps duplicate key to sqlState 23505":
    discard db.execUpdate(
      "insert into t004_probe (id) values ($1)", @[intParam(3)])
    var caught = false
    try:
      discard db.execUpdate(
        "insert into t004_probe (id) values ($1)", @[intParam(3)])
    except DbError as error:
      caught = true
      check error.sqlState == "23505"
    check caught

  test "transaction rolls back on error":
    var caught = false
    try:
      db.tx(proc(conn: DbConn) =
        discard conn.execUpdate(
          "insert into t004_probe (id) values ($1)", @[intParam(4)])
        raise newException(ValueError, "boom")
      )
    except ValueError:
      caught = true
    check caught
    check db.queryOne(
      "select id from t004_probe where id = $1", @[intParam(4)]).isNone

  test "a bound facade joins the caller's transaction":
    # The write the facade performs must roll back with the transaction that
    # owns the connection: it is the same transaction, not a second one.
    var caught = false
    try:
      db.tx(proc(conn: DbConn) =
        let scoped = db.boundTo(conn)
        discard scoped.execUpdate(
          "insert into t004_probe (id) values ($1)", @[intParam(5)])
        check scoped.queryOne(
          "select id from t004_probe where id = $1", @[intParam(5)]).isSome
        raise newException(ValueError, "boom")
      )
    except ValueError:
      caught = true
    check caught
    check db.queryOne(
      "select id from t004_probe where id = $1", @[intParam(5)]).isNone

  test "a nested tx on a bound facade becomes a savepoint":
    # A helper that opens its own transaction, fails and rolls back must leave
    # the caller's transaction usable: the savepoint contains the damage.
    db.tx(proc(conn: DbConn) =
      let scoped = db.boundTo(conn)
      try:
        scoped.tx(proc(inner: DbConn) =
          discard inner.execUpdate(
            "insert into t004_probe (id) values ($1)", @[intParam(6)])
          raise newException(ValueError, "inner boom"))
      except ValueError:
        discard
      discard scoped.execUpdate(
        "insert into t004_probe (id) values ($1)", @[intParam(7)]))
    check db.queryOne(
      "select id from t004_probe where id = $1", @[intParam(6)]).isNone
    check db.queryOne(
      "select id from t004_probe where id = $1", @[intParam(7)]).isSome

  test "a NULL column reads as none":
    let row = Row(names: @["note"], values: @[none(string)])
    check row.getOpt("note").isNone

  test "a boolean reads from the text format":
    let row = Row(names: @["enabled", "disabled"],
      values: @[some("t"), some("f")])
    check row.getBool("enabled")
    check not row.getBool("disabled")

  test "a malformed uuid names the column":
    let row = Row(names: @["player_id"], values: @[some("0190")])
    var message = ""
    try:
      discard row.getUuid("player_id")
    except ValueError as error:
      message = error.msg
    check message.contains("player_id")

  test "a timestamptz keeps its fractional second":
    let row = Row(names: @["earned_at"],
      values: @[some("2026-11-07 12:00:00.5+07")])
    let at = row.getTimestamp("earned_at")
    check at == parse("2026-11-07T05:00:00.500Z",
      "yyyy-MM-dd'T'HH:mm:ss'.'fff'Z'", utc())
    check at.nanosecond == 500_000_000

  test "every pooled connection carries the configured timeouts":
    let probe = openDb(dsn(), 2, statementTimeoutMs = 750, lockTimeoutMs = 250)
    defer: probe.close()
    let settings = probe.connectionTimeouts()
    check settings.len == 2
    for (statement, lock, idle) in settings:
      check statement == "750ms"
      check lock == "250ms"
      # An idle bound follows the statement bound unless one is passed.
      check idle == "750ms"

  test "the defaults leave a CLI pool without web caps":
    let probe = openDb(dsn(), 1)
    defer: probe.close()
    for (statement, lock, idle) in probe.connectionTimeouts():
      check statement == "0"
      check lock == "0"
      check idle == "0"

  test "a statement that runs past the bound is cancelled":
    let probe = openDb(dsn(), 1, statementTimeoutMs = 200)
    defer: probe.close()
    let begin = getMonoTime()
    var state = ""
    try:
      # Not a synchronisation wait: the statement itself is the subject of the
      # test, and `statement_timeout` must cancel it.
      discard probe.queryOne("select pg_sleep(20)")
    except DbError as error:
      state = error.sqlState
    check state == "57014"
    check (getMonoTime() - begin).inMilliseconds < 5000

  test "pool checkout raises DbPoolTimeout at the configured deadline":
    let probe = openDb(dsn(), 1, acquireTimeoutMs = 120)
    defer: probe.close()
    var started: Atomic[int]
    var released: Atomic[int]
    var thread: Thread[HolderArgs]
    createThread(thread, holdConnection, HolderArgs(db: probe,
      started: addr started, released: addr released))
    waitUntil(proc(): bool = started.load(moRelaxed) == 1,
      proc(): string = "the holder never checked the connection out",
      timeoutMs = 30000)
    let begin = getMonoTime()
    var caught = false
    try:
      discard probe.queryOne("select 1 as one")
    except DbPoolTimeout:
      caught = true
    check caught
    check (getMonoTime() - begin).inMilliseconds < 2000
    # The holder is released only now, so the connection stayed checked out for
    # exactly as long as this test needed it.
    released.store(1, moRelaxed)
    joinThread(thread)

  test "a whole-second timestamptz has no fraction":
    let row = Row(names: @["earned_at"],
      values: @[some("2026-11-07 12:00:00+07")])
    let at = row.getTimestamp("earned_at")
    check at == parse("2026-11-07T05:00:00Z",
      "yyyy-MM-dd'T'HH:mm:ss'Z'", utc())
    check at.nanosecond == 0
