import std/[locks, options, strutils]
import db_connector/postgres

type
  DbParamKind* = enum
    dpNull, dpText, dpInt, dpBool, dpUuid, dpTimestamp

  DbParam* = object
    case kind*: DbParamKind
    of dpNull: discard
    of dpText: text*: string
    of dpInt: intValue*: int64
    of dpBool: boolValue*: bool
    of dpUuid: uuidValue*: string
    of dpTimestamp: timestampValue*: string

  Row* = object
    names*: seq[string]
    values*: seq[Option[string]]

  DbConn* = object
    ## A checked-out connection. Only valid inside `tx`.
    conn: PPGconn

  Db* = ref object
    lock: Lock
    cond: Cond
    available: seq[PPGconn]
    size*: int

  DbError* = object of CatchableError
    sqlState*: string
    constraint*: string

const
  PG_DIAG_SQLSTATE = 67.cint
  PG_DIAG_CONSTRAINT_NAME = 110.cint

proc nullParam*(): DbParam = DbParam(kind: dpNull)
proc textParam*(value: string): DbParam = DbParam(kind: dpText, text: value)
proc intParam*(value: int64): DbParam = DbParam(kind: dpInt, intValue: value)
proc boolParam*(value: bool): DbParam = DbParam(kind: dpBool, boolValue: value)
proc uuidParam*(value: string): DbParam = DbParam(kind: dpUuid, uuidValue: value)
proc timestampParam*(value: string): DbParam =
  ## RFC 3339 UTC; PostgreSQL parses the text representation.
  DbParam(kind: dpTimestamp, timestampValue: value)

proc asText*(param: DbParam): string =
  case param.kind
  of dpNull: ""
  of dpText: param.text
  of dpInt: $param.intValue
  of dpBool: (if param.boolValue: "true" else: "false")
  of dpUuid: param.uuidValue
  of dpTimestamp: param.timestampValue

proc errorField(res: PPGresult, code: cint): string =
  let value = pqresultErrorField(res, code)
  if value == nil: "" else: $value

proc raiseResultError(res: PPGresult) {.noreturn.} =
  var error = newException(DbError, $pqresultErrorMessage(res))
  error.sqlState = errorField(res, PG_DIAG_SQLSTATE)
  error.constraint = errorField(res, PG_DIAG_CONSTRAINT_NAME)
  raise error

proc resultToRows(res: PPGresult): seq[Row] =
  let columns = pqnfields(res)
  let rows = pqntuples(res)
  # Every row of a result shares the same column names, so they are read once
  # and handed to each row instead of being re-read and re-allocated per row.
  var names = newSeq[string](columns)
  for c in 0 ..< columns:
    names[c] = $pqfname(res, c)
  result = newSeq[Row](rows)
  for r in 0 ..< rows:
    var values = newSeq[Option[string]](columns)
    for c in 0 ..< columns:
      if pqgetisnull(res, r, c) == 0:
        values[c] = some($pqgetvalue(res, r, c))
    result[r] = Row(names: names, values: values)

type BoundParams = object
  values: cstringArray
  ## Owns the bytes every pointer in `values` refers to. libpq reads the
  ## pointers during PQexecParams, so these strings must outlive the call.
  backing: seq[string]

proc bindValues(params: seq[DbParam]): BoundParams =
  result.values = cast[cstringArray](alloc0(params.len * sizeof(cstring)))
  result.backing = newSeq[string](params.len)
  for i, param in params:
    if param.kind != dpNull:
      result.backing[i] = param.asText
      result.values[i] = result.backing[i].cstring

proc freeValues(bound: BoundParams) =
  let count = bound.backing.len
  for i in 0 ..< count:
    bound.values[i] = nil
  dealloc(bound.values)
  # Keep the backing storage alive past the libpq call explicitly.
  discard bound.backing.len

proc executeRows(conn: PPGconn, sql: string, params: seq[DbParam]): seq[Row] =
  ## The SQL string is passed verbatim with $1..$n placeholders, so a jsonb `?`
  ## operator is never rewritten or rejected.
  let bound = bindValues(params)
  try:
    let res = pqexecParams(
      conn, sql.cstring, params.len.int32, nil, bound.values, nil, nil, 0)
    if res == nil:
      raise newException(DbError, $pqerrorMessage(conn))
    try:
      if pqresultStatus(res) != PGRES_TUPLES_OK:
        raiseResultError(res)
      result = resultToRows(res)
    finally:
      pqclear(res)
  finally:
    freeValues(bound)

proc executeCommand(conn: PPGconn, sql: string, params: seq[DbParam]): int =
  let bound = bindValues(params)
  try:
    let res = pqexecParams(
      conn, sql.cstring, params.len.int32, nil, bound.values, nil, nil, 0)
    if res == nil:
      raise newException(DbError, $pqerrorMessage(conn))
    try:
      if pqresultStatus(res) notin {PGRES_COMMAND_OK, PGRES_TUPLES_OK}:
        raiseResultError(res)
      let tag = $pqcmdTuples(res)
      if tag.len == 0: 0 else: parseInt(tag)
    finally:
      pqclear(res)
  finally:
    freeValues(bound)

proc query*(conn: DbConn, sql: string, params: seq[DbParam] = @[]): seq[Row] =
  executeRows(conn.conn, sql, params)

proc queryOne*(conn: DbConn, sql: string,
               params: seq[DbParam] = @[]): Option[Row] =
  let rows = query(conn, sql, params)
  if rows.len == 0: none(Row) else: some(rows[0])

proc execUpdate*(conn: DbConn, sql: string, params: seq[DbParam] = @[]): int =
  executeCommand(conn.conn, sql, params)


proc execScript*(conn: DbConn, sql: string) =
  ## Runs a multi-statement SQL file. Used by dbtools migrations and seeds;
  ## regular application queries must use `query`/`execUpdate`.
  let res = pqexec(conn.conn, sql.cstring)
  if res == nil:
    raise newException(DbError, $pqerrorMessage(conn.conn))
  try:
    if pqresultStatus(res) notin {PGRES_COMMAND_OK, PGRES_TUPLES_OK}:
      raiseResultError(res)
  finally:
    pqclear(res)

proc `[]`*(row: Row, name: string): Option[string] =
  for i, column in row.names:
    if column == name:
      return row.values[i]
  raise newException(KeyError, "column not found: " & name)

proc get*(row: Row, name: string): string =
  let value = row[name]
  if value.isNone:
    raise newException(ValueError, "column is NULL: " & name)
  value.get

proc has*(row: Row, name: string): bool =
  for column in row.names:
    if column == name:
      return true
  false

proc openDb*(dsn: string, poolSize: int): Db =
  if poolSize < 1:
    raise newException(ValueError, "pool size must be at least 1")
  result = Db(size: poolSize)
  initLock(result.lock)
  initCond(result.cond)
  for _ in 0 ..< poolSize:
    let conn = pqconnectdb(dsn.cstring)
    if conn == nil or pqstatus(conn) != CONNECTION_OK:
      let detail =
        if conn == nil: "cannot allocate connection"
        else: $pqerrorMessage(conn)
      raise newException(DbError, "cannot connect to PostgreSQL: " & detail)
    result.available.add(conn)

proc close*(db: Db) =
  acquire(db.lock)
  for conn in db.available:
    pqfinish(conn)
  db.available.setLen(0)
  release(db.lock)
  deinitCond(db.cond)
  deinitLock(db.lock)

proc acquireConn(db: Db): PPGconn =
  acquire(db.lock)
  while db.available.len == 0:
    wait(db.cond, db.lock)
  result = db.available.pop()
  release(db.lock)

proc releaseConn(db: Db, conn: PPGconn) =
  acquire(db.lock)
  db.available.add(conn)
  signal(db.cond)
  release(db.lock)

proc withConn[T](db: Db, body: proc(conn: DbConn): T): T =
  let conn = acquireConn(db)
  try:
    body(DbConn(conn: conn))
  finally:
    releaseConn(db, conn)

proc query*(db: Db, sql: string, params: seq[DbParam] = @[]): seq[Row] =
  withConn(db, proc(conn: DbConn): seq[Row] = conn.query(sql, params))

proc queryOne*(db: Db, sql: string, params: seq[DbParam] = @[]): Option[Row] =
  withConn(db, proc(conn: DbConn): Option[Row] = conn.queryOne(sql, params))

proc execUpdate*(db: Db, sql: string, params: seq[DbParam] = @[]): int =
  withConn(db, proc(conn: DbConn): int = conn.execUpdate(sql, params))

proc read*[T](db: Db, body: proc(conn: DbConn): T): T =
  ## Runs `body` on one connection without opening a transaction. Prefer
  ## `query`/`queryOne` for single statements: they release the connection as
  ## soon as the statement is done. Reach for this only when a helper needs a
  ## `DbConn` for a short, read-only burst and the pool must not be pinned for
  ## the whole computation.
  withConn(db, body)

proc tx*[T](db: Db, body: proc(conn: DbConn): T): T =
  withConn(db, proc(conn: DbConn): T =
    let beginRes = pqexec(conn.conn, "BEGIN")
    try:
      if pqresultStatus(beginRes) != PGRES_COMMAND_OK:
        raiseResultError(beginRes)
    finally:
      pqclear(beginRes)
    try:
      result = body(conn)
      let commitRes = pqexec(conn.conn, "COMMIT")
      try:
        if pqresultStatus(commitRes) != PGRES_COMMAND_OK:
          raiseResultError(commitRes)
      finally:
        pqclear(commitRes)
    except CatchableError:
      let rollbackRes = pqexec(conn.conn, "ROLLBACK")
      if rollbackRes != nil:
        pqclear(rollbackRes)
      raise
  )
