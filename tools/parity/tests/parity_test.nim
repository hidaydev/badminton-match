import std/[exitprocs, json, options, os, strutils, unittest]
import db/db
import ../normalizer
import ../state as parityState

## The state suites need a database, because the digest is computed by
## PostgreSQL and the self-test mutates a row inside a transaction. They never
## read `testdata/parity/v2/state.json` or its fixture: every projection below
## points at a scratch schema this suite creates and drops, so a run cannot
## disturb the recorded corpus.
##
## Without MAJADU_PG_DSN the file reports a counted skip (status 77) instead of
## pretending the digest was checked.

let dsn = getEnv("MAJADU_PG_DSN")

if dsn.len == 0:
  echo "SKIP parity state suite: MAJADU_PG_DSN not set"
  quit(77)

const scratchPrefix = "parity_tl10"

let scratchSchema = scratchPrefix & "_" & $getCurrentProcessId()
let scratchDir = getTempDir() / ("parity-state-" & $getCurrentProcessId())

var database: Db

proc bootstrap() =
  database = openDb(dsn, 1)
  database.tx(proc(conn: DbConn) =
    conn.execScript(
      "drop schema if exists " & scratchSchema & " cascade;" &
      "create schema " & scratchSchema & ";" &
      "create table " & scratchSchema &
        ".items (id int primary key, name text not null, " &
        "note text not null default '');" &
      "insert into " & scratchSchema &
        ".items (id, name) values (1, 'alpha'), (2, 'beta');")
  )
  createDir(scratchDir)

proc cleanup() {.noconv.} =
  ## Runs at exit, where the module-level strings may already have been
  ## destroyed: both names are computed again instead of being read back.
  let schema = scratchPrefix & "_" & $getCurrentProcessId()
  let directory = getTempDir() / ("parity-state-" & $getCurrentProcessId())
  try:
    if database != nil:
      database.tx(proc(conn: DbConn) =
        conn.execScript("drop schema if exists " & schema & " cascade;")
      )
      database.close()
    if dirExists(directory):
      removeDir(directory)
  except CatchableError:
    discard

bootstrap()
addExitProc(cleanup)

proc itemsProjection(whereClause: string = ""; orderBy: seq[string] = @["id"]):
    parityState.Projection =
  parityState.Projection(table: scratchSchema & ".items",
    columns: @["id", "name"], orderBy: orderBy, whereClause: whereClause)

suite "normalizer":
  test "replaces uuids, timestamps and share codes":
    let value =
      "id 11111111-2222-3333-4444-555555555555 at 2026-11-03T12:00:00Z in /s/abc123"
    check normalizeText(value) == "id {uuid} at {timestamp} in /s/{code}"

  test "sorts object keys and keeps arrays":
    let node = parseJson(
      """{"b":"2026-11-03T12:00:00Z","a":[1,"11111111-2222-3333-4444-555555555555"]}""")
    let normalized = normalizeJson(node)
    check $normalized == """{"a":[1,"{uuid}"],"b":"{timestamp}"}"""

  test "masks PostgreSQL text timestamps":
    check normalizeText("2026-11-04 14:06:13.353736+07") == "{timestamp}"

  test "masks websocket tickets and share codes":
    check normalizeText("ce9b722a88affbecd9508a7fdce9734732c3d0502dd3d554aca0abf9ff05478e") ==
      "{ticket}"
    check normalizeText("5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a") == "{shareCode}"

  test "masks oidc flow parameters but keeps the query":
    check normalizeText(
      "https://idp/authorize?state=deadbeef&nonce=cafe&code_challenge=xyz&client_id=1") ==
      "{authorizeUrl}?state={random}&nonce={random}&code_challenge={random}&client_id=1"

  test "masks the board as-of date only":
    let node = parseJson("""{"asOf":"2026-11-04","date":"2026-11-03"}""")
    check $normalizeJson(node) == """{"asOf":"{date}","date":"2026-11-03"}"""

suite "state projections":
  test "projection SQL pins the columns and the order":
    let projection = parityState.Projection(
      table: "platform.community",
      columns: @["slug", "name"],
      orderBy: @["slug"])
    let sql = parityState.projectionSql(projection)
    check sql.contains("select slug, name from platform.community order by slug")
    check sql.contains("jsonb_agg")

  test "projection SQL keeps an optional filter":
    let projection = parityState.Projection(
      table: "platform.community",
      columns: @["slug"],
      orderBy: @["slug"],
      whereClause: "slug = 'parity'")
    check parityState.projectionSql(projection).contains(
      "from platform.community where slug = 'parity' order by slug")

  test "a projection without ORDER BY is refused":
    let projection = parityState.Projection(
      table: "platform.community",
      columns: @["slug"])
    expect ValueError:
      discard parityState.projectionSql(projection)

suite "loadState":
  test "reads the projections, the optional where and the selftest block":
    let path = scratchDir / "full.json"
    writeFile(path, """
{
  "projections": [
    {
      "table": "platform.community",
      "columns": ["slug", "name"],
      "orderBy": ["slug"],
      "where": "slug = 'parity'",
      "rows": 3,
      "sha256": "abc"
    },
    {
      "table": "platform.user",
      "columns": ["display_name"],
      "orderBy": ["display_name"]
    }
  ],
  "selftest": {
    "projection": "platform.community",
    "sql": "update platform.community set name = name where slug = 'parity'"
  }
}
""")
    let state = parityState.loadState(path)
    check state.path == path
    check state.projections.len == 2
    check state.projections[0].table == "platform.community"
    check state.projections[0].columns == @["slug", "name"]
    check state.projections[0].orderBy == @["slug"]
    check state.projections[0].whereClause == "slug = 'parity'"
    check state.projections[0].rows == 3
    check state.projections[0].digest == "abc"
    check state.projections[1].whereClause == ""
    check state.projections[1].rows == 0
    check state.projections[1].digest == ""
    check state.selftestTable == "platform.community"
    check state.selftestSql ==
      "update platform.community set name = name where slug = 'parity'"

  test "a state without a selftest block leaves it empty":
    let path = scratchDir / "no-selftest.json"
    writeFile(path, """
{"projections": [{"table": "t", "columns": ["c"], "orderBy": ["c"]}]}
""")
    let state = parityState.loadState(path)
    check state.selftestSql == ""
    check state.selftestTable == ""

  test "a missing file is refused":
    expect ValueError:
      discard parityState.loadState(scratchDir / "absent.json")

suite "save":
  test "round-trips the projections and the selftest block":
    var state = parityState.StateFile(
      path: scratchDir / "round-trip.json",
      projections: @[itemsProjection(whereClause = "id > 0"),
        itemsProjection(orderBy = @["name"])],
      selftestTable: scratchSchema & ".items",
      selftestSql: "update " & scratchSchema &
        ".items set note = 'x' where id = 1")
    state.projections[0].rows = 2
    state.projections[0].digest = "aaaa"
    parityState.save(state)

    let loaded = parityState.loadState(state.path)
    check loaded.projections.len == 2
    check loaded.projections[0].whereClause == "id > 0"
    check loaded.projections[0].rows == 2
    check loaded.projections[0].digest == "aaaa"
    check loaded.projections[0].columns == @["id", "name"]
    check loaded.projections[1].orderBy == @["name"]
    check loaded.selftestTable == scratchSchema & ".items"
    check loaded.selftestSql ==
      "update " & scratchSchema & ".items set note = 'x' where id = 1"

  test "where is omitted when it is empty":
    let state = parityState.StateFile(path: scratchDir / "no-where.json",
      projections: @[itemsProjection()])
    parityState.save(state)
    let document = parseFile(state.path)
    check not document["projections"][0].hasKey("where")
    check document["projections"][0]["rows"].getInt() == 0
    check parityState.loadState(state.path).projections[0].whereClause == ""

suite "problemsFor":
  test "a projection without columns is reported":
    let problems = parityState.problemsFor(database,
      @[parityState.Projection(table: "platform.community")])
    check problems.len == 1
    check problems[0].contains("platform.community: no columns")

  test "a projection without ORDER BY is reported":
    let problems = parityState.problemsFor(database,
      @[parityState.Projection(table: "platform.community",
        columns: @["slug"])])
    check problems.len == 1
    check problems[0].contains("platform.community: no ORDER BY")

  test "a zero-row projection is reported":
    let problems = parityState.problemsFor(database,
      @[itemsProjection(whereClause = "id < 0")])
    check problems.len == 1
    check problems[0].contains("projection returned 0 rows")

  test "a digest mismatch is reported":
    var projection = itemsProjection()
    projection.digest = repeat('0', 64)
    let problems = parityState.problemsFor(database, @[projection])
    check problems.len == 1
    check problems[0].contains("state drifted (rows=2)")

  test "a matching digest has no problem":
    var projection = itemsProjection()
    projection.digest = parityState.compute(database, projection)[1]
    check parityState.problemsFor(database, @[projection]).len == 0

suite "snapshot":
  test "writes the digest and the row count for every projection":
    var state = parityState.StateFile(projections: @[itemsProjection(),
      itemsProjection(orderBy = @["name"])])
    parityState.snapshot(database, state)
    for projection in state.projections:
      let (rows, digest) = parityState.compute(database, projection)
      check projection.rows == rows
      check projection.digest == digest
    check state.projections[0].rows == 2
    check state.projections[0].digest.len == 64

suite "selftest":
  proc selftestState(sql: string): parityState.StateFile =
    parityState.StateFile(projections: @[itemsProjection()],
      selftestTable: scratchSchema & ".items", selftestSql: sql)

  proc itemName(id: int): string =
    database.queryOne("select name from " & scratchSchema &
      ".items where id = " & $id).get.get("name")

  test "a one-row mutation that is rolled back passes":
    let state = selftestState("update " & scratchSchema &
      ".items set name = 'changed' where id = 1")
    let problems = parityState.selftest(database, state)
    check problems.len == 0
    check itemName(1) == "alpha"

  test "a mutation that changes no row is reported":
    let problems = parityState.selftest(database, selftestState("update " &
      scratchSchema & ".items set name = 'changed' where id = 99"))
    check problems.len == 1
    check problems[0].contains("changed 0 rows, expected 1")

  test "a mutation that changes more than one row is reported":
    let problems = parityState.selftest(database, selftestState("update " &
      scratchSchema & ".items set name = name"))
    check problems.len == 1
    check problems[0].contains("changed 2 rows, expected 1")

  test "a mutation that leaves the digest alone is reported":
    # `note` is not part of the projection, so exactly one row changes and the
    # digest does not: the guard has to notice that the hash is insensitive.
    let problems = parityState.selftest(database, selftestState("update " &
      scratchSchema & ".items set note = 'touched' where id = 1"))
    check problems.len == 1
    check problems[0].contains("did not change the digest")

  test "a state without a selftest block is reported":
    let problems = parityState.selftest(database,
      parityState.StateFile(projections: @[itemsProjection()]))
    check problems == @["state.json has no selftest block"]

  test "a selftest projection that is not declared is reported":
    let state = parityState.StateFile(projections: @[itemsProjection()],
      selftestTable: scratchSchema & ".missing",
      selftestSql: "update " & scratchSchema & ".items set note = 'x'")
    let problems = parityState.selftest(database, state)
    check problems.len == 1
    check problems[0].contains("selftest projection is not declared: " &
      scratchSchema & ".missing")
