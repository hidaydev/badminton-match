import std/[options, os, unittest]
import ../../db/db

proc dsn(): string =
  getEnv("MAJADU_PG_DSN")

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
