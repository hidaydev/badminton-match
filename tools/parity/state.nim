## Fixture-state fingerprint for the v2 parity corpus (T-071).
##
## `state.json` declares one column projection per table with an explicit
## `ORDER BY`. The digest proves that a replay ended on the same rows it was
## recorded against; row counts are checked too, so a projection that silently
## matches nothing can never freeze into a constant hash.

import std/[json, options, os, strutils]
import db/db
import sha256

type
  Projection* = object
    table*: string
    columns*: seq[string]
    orderBy*: seq[string]
    whereClause*: string
    rows*: int
    digest*: string

  StateFile* = object
    path*: string
    projections*: seq[Projection]
    selftestTable*: string
    selftestSql*: string

  RollbackSignal = object of CatchableError

proc strings(node: JsonNode, key: string): seq[string] =
  if not node.hasKey(key):
    return @[]
  for item in node[key]:
    result.add(item.getStr())

proc loadState*(path: string): StateFile =
  result.path = path
  if not fileExists(path):
    raise newException(ValueError, "state file not found: " & path)
  let document = parseFile(path)
  for entry in document["projections"]:
    result.projections.add(Projection(
      table: entry["table"].getStr(),
      columns: strings(entry, "columns"),
      orderBy: strings(entry, "orderBy"),
      whereClause: if entry.hasKey("where"): entry["where"].getStr() else: "",
      rows: if entry.hasKey("rows"): entry["rows"].getInt() else: 0,
      digest: if entry.hasKey("sha256"): entry["sha256"].getStr() else: "",
    ))
  if document.hasKey("selftest"):
    result.selftestTable = document["selftest"]["projection"].getStr()
    result.selftestSql = document["selftest"]["sql"].getStr()

proc projectionSql*(projection: Projection): string =
  ## The digest input is the canonical JSON of the projected rows. `jsonb`
  ## sorts object keys, so two equal result sets serialise byte-identically.
  if projection.columns.len == 0:
    raise newException(ValueError, "projection has no columns: " & projection.table)
  if projection.orderBy.len == 0:
    raise newException(ValueError, "projection has no ORDER BY: " & projection.table)
  let columns = projection.columns.join(", ")
  let whereClause =
    if projection.whereClause.len > 0: " where " & projection.whereClause else: ""
  let orderBy = projection.orderBy.join(", ")
  "select count(*)::bigint as row_count, " &
    "coalesce(jsonb_agg(to_jsonb(p))::text, '[]') as body " &
    "from (select " & columns & " from " & projection.table & whereClause &
    " order by " & orderBy & ") p"

proc computeWith*(conn: DbConn, projection: Projection): (int, string) =
  let row = conn.queryOne(projectionSql(projection))
  if row.isNone:
    raise newException(ValueError, "projection returned no row: " & projection.table)
  (parseInt(row.get.get("row_count")), sha256Hex(row.get.get("body")))

proc compute*(db: Db, projection: Projection): (int, string) =
  let row = db.queryOne(projectionSql(projection))
  if row.isNone:
    raise newException(ValueError, "projection returned no row: " & projection.table)
  (parseInt(row.get.get("row_count")), sha256Hex(row.get.get("body")))

proc problemsFor*(db: Db, projections: seq[Projection]): seq[string] =
  for projection in projections:
    if projection.columns.len == 0:
      result.add(projection.table & ": no columns")
      continue
    if projection.orderBy.len == 0:
      result.add(projection.table & ": no ORDER BY")
      continue
    let (rows, digest) = compute(db, projection)
    if rows == 0:
      result.add(projection.table & ": projection returned 0 rows")
    elif projection.digest.len > 0 and projection.digest != digest:
      result.add(projection.table & ": state drifted (rows=" & $rows & ")")

proc snapshot*(db: Db, state: var StateFile) =
  for index in 0 ..< state.projections.len:
    let (rows, digest) = compute(db, state.projections[index])
    state.projections[index].rows = rows
    state.projections[index].digest = digest

proc toJson*(state: StateFile): JsonNode =
  var projections = newJArray()
  for projection in state.projections:
    var entry = %*{
      "table": projection.table,
      "columns": %projection.columns,
      "orderBy": %projection.orderBy,
      "rows": projection.rows,
      "sha256": projection.digest,
    }
    if projection.whereClause.len > 0:
      entry["where"] = %projection.whereClause
    projections.add(entry)
  result = %*{"projections": projections}
  if state.selftestSql.len > 0:
    result["selftest"] = %*{
      "projection": state.selftestTable,
      "sql": state.selftestSql,
    }

proc save*(state: StateFile) =
  writeFile(state.path, pretty(toJson(state), indent = 2) & "\n")

proc selftest*(db: Db, state: StateFile): seq[string] =
  ## Proves the digest is sensitive to a row mutation, and that a projection
  ## with no rows is reported instead of hashing to a constant. The mutation
  ## runs inside a transaction that is always rolled back.
  if state.selftestSql.len == 0 or state.selftestTable.len == 0:
    return @["state.json has no selftest block"]
  var target: Option[Projection]
  for projection in state.projections:
    if projection.table == state.selftestTable:
      target = some(projection)
  if target.isNone:
    return @["selftest projection is not declared: " & state.selftestTable]
  let probe = target.get
  let (_, before) = compute(db, probe)
  var rollback = false
  try:
    db.tx(proc(conn: DbConn) =
      let changed = conn.execUpdate(state.selftestSql)
      if changed != 1:
        raise newException(ValueError,
          "selftest mutation changed " & $changed & " rows, expected 1")
      let (_, after) = computeWith(conn, probe)
      if after == before:
        raise newException(ValueError,
          "selftest mutation did not change the digest")
      rollback = true
      raise newException(RollbackSignal, "rollback")
    )
  except RollbackSignal:
    discard
  except ValueError as error:
    result.add(error.msg)
    return
  if not rollback:
    result.add("selftest transaction did not run")
    return
  let (_, restored) = compute(db, probe)
  if restored != before:
    result.add("selftest mutation was not rolled back")
  # The zero-row guard is part of the contract: a broken projection must fail.
  var empty = probe
  empty.whereClause = "false"
  empty.digest = ""
  if problemsFor(db, @[empty]).len == 0:
    result.add("zero-row projection was not reported")

proc digestProblems*(db: Db, state: StateFile): seq[string] =
  problemsFor(db, state.projections)
