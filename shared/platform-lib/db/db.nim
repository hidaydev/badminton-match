import std/[locks, options, strutils, times]
when defined(posix):
  import std/posix
import db_connector/postgres

type
  DbParamKind* = enum
    dpNull, dpText, dpInt, dpBool, dpTimestamp

  DbParam* = object
    case kind*: DbParamKind
    of dpNull: discard
    of dpText: text*: string
    of dpInt: intValue*: int64
    of dpBool: boolValue*: bool
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
    ## Set only on a facade built by `boundTo`: the connection the caller is
    ## already inside a transaction with. Such a facade never takes a pooled
    ## connection and never opens a transaction of its own.
    pinned: PPGconn
    size*: int
    ## Milliseconds. Zero disables that bound, which keeps a tool that opens a
    ## one-connection pool on a private database from inheriting a web timeout.
    acquireTimeoutMs*: int
    statementTimeoutMs*: int
    lockTimeoutMs*: int
    idleTimeoutMs*: int

  DbError* = object of CatchableError
    sqlState*: string
    constraint*: string

  DbPoolTimeout* = object of DbError
    ## The pool gave the caller no connection before its deadline. The HTTP
    ## layer maps this to 503 instead of waiting until the process wedges.

const
  PG_DIAG_SQLSTATE = 67.cint
  PG_DIAG_CONSTRAINT_NAME = 110.cint
  ## The API process edge reads MAJADU_DB_* and passes these values in.
  ## `openDb` itself defaults every bound to zero, because a CLI tool
  ## (dbtools migrate, tools/import, ratingingest) must not run under a web
  ## timeout: a large migration or ETL would be killed halfway through.
  defaultAcquireTimeoutMs* = 5000
  defaultStatementTimeoutMs* = 15000
  defaultLockTimeoutMs* = 5000

proc nullParam*(): DbParam = DbParam(kind: dpNull)
proc textParam*(value: string): DbParam = DbParam(kind: dpText, text: value)
proc intParam*(value: int64): DbParam = DbParam(kind: dpInt, intValue: value)
proc boolParam*(value: bool): DbParam = DbParam(kind: dpBool, boolValue: value)
proc timestampParam*(value: string): DbParam =
  ## RFC 3339 UTC; PostgreSQL parses the text representation.
  DbParam(kind: dpTimestamp, timestampValue: value)

proc textOrNull*(value: string): DbParam =
  ## An empty string is "no value": the column keeps NULL instead of `''`.
  if value.len == 0: nullParam() else: textParam(value)

proc textArray*(values: seq[string]): string =
  ## An array literal for one parameter: a batched write passes the whole set in
  ## one round trip, and a value with a comma, a brace or a quote inside it (a
  ## match key is free text) survives, unlike a bare join.
  var quoted: seq[string] = @[]
  for value in values:
    quoted.add("\"" & value.replace("\\", "\\\\").replace("\"", "\\\"") & "\"")
  "{" & quoted.join(",") & "}"

proc asText*(param: DbParam): string =
  case param.kind
  of dpNull: ""
  of dpText: param.text
  of dpInt: $param.intValue
  of dpBool: (if param.boolValue: "true" else: "false")
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

var
  # The statement counter is a test hook: a suite proves that a batched write
  # costs a fixed number of round trips instead of one per row. Only a
  # transaction's own statements are counted, because its body is what a write
  # holds its row locks for; `BEGIN`/`COMMIT` never reach the executors.
  countingStatements {.threadvar.}: bool
  transactionStatements {.threadvar.}: int
  savepointSeq {.threadvar.}: int

proc countStatement() =
  if countingStatements:
    inc transactionStatements

proc statementsInTransaction*(): int =
  ## How many statements the most recent transaction sent, `BEGIN`/`COMMIT`
  ## excluded. The suites read it to keep a batched write from growing with its
  ## row count.
  transactionStatements

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
  countStatement()
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
  countStatement()
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
  countStatement()
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

proc getOpt*(row: Row, name: string): Option[string] =
  ## The NULL-safe read: a column the schema allows to be NULL becomes `none`
  ## here instead of raising at the call site.
  row[name]

proc has*(row: Row, name: string): bool =
  for column in row.names:
    if column == name:
      return true
  false

proc getInt*(row: Row, name: string): int =
  ## PostgreSQL sends every type in its text format, so the conversion carries
  ## the column name: a parse failure points at the column, not the statement.
  let value = row.get(name)
  try:
    parseInt(value)
  except ValueError:
    raise newException(ValueError,
      "column is not an integer: " & name & " = " & value)

proc getInt64*(row: Row, name: string): int64 = system.int64(row.getInt(name))

proc getBool*(row: Row, name: string): bool =
  ## PostgreSQL renders a boolean as `t`/`f` in the text result format.
  case row.get(name)
  of "t": true
  of "f": false
  else:
    raise newException(ValueError,
      "column is not a boolean: " & name & " = " & row.get(name))

proc isHexDigit(ch: char): bool =
  ch in {'0'..'9', 'a'..'f', 'A'..'F'}

proc getUuid*(row: Row, name: string): string =
  ## A uuid column always comes back as its canonical 8-4-4-4-12 text, so a
  ## value that does not match means the query or the schema is wrong.
  const groups = [8, 4, 4, 4, 12]
  result = row.get(name)
  var offset = 0
  var valid = result.len == 36
  if valid:
    for groupIndex, width in groups:
      for index in 0 ..< width:
        if not isHexDigit(result[offset + index]):
          valid = false
      offset += width
      if groupIndex < groups.high:
        if result[offset] != '-':
          valid = false
        inc offset
  if not valid:
    raise newException(ValueError,
      "column is not a uuid: " & name & " = " & result)

proc parseTimestamp(value: string): DateTime =
  ## PostgreSQL renders a timestamptz in the ISO DateStyle as
  ## `yyyy-MM-dd HH:mm:ss[.f]±HH[:MM]`. Nim's parser needs the offset colon and
  ## exactly six fraction digits, so both are normalized first.
  var separator = -1
  for index in countdown(value.len - 1, 0):
    if index > 10 and value[index] in {'+', '-'}:
      separator = index
      break
  if separator < 0:
    raise newException(TimeParseError, "timestamp has no offset: " & value)
  var head = value[0 ..< separator]
  var zone = value[separator .. ^1]
  if zone.len == 3:
    zone.add(":00")
  let dot = head.find('.')
  if dot < 0:
    return parse(head & zone, "yyyy-MM-dd HH:mm:sszzz", utc())
  var fraction = head[dot + 1 .. ^1]
  if fraction.len > 6:
    fraction.setLen(6)
  while fraction.len < 6:
    fraction.add('0')
  head.setLen(dot)
  head.add('.')
  head.add(fraction)
  parse(head & zone, "yyyy-MM-dd HH:mm:ss'.'ffffffzzz", utc())

proc getTimestamp*(row: Row, name: string): DateTime =
  ## A `timestamptz` reaches Nim as a value, not as the server's text.
  let value = row.get(name)
  try:
    parseTimestamp(value)
  except TimeParseError:
    raise newException(ValueError,
      "column is not a timestamp: " & name & " = " & value)

proc configureConn(conn: PPGconn, statementMs, lockMs, idleMs: int) =
  ## Applied when the connection is created, so every path through the pool
  ## inherits the bound. `options=-c ...` in the DSN would do the same but would
  ## be lost the moment a caller passes a bare URL.
  var statements: seq[string] = @[]
  if statementMs > 0:
    statements.add("set statement_timeout = " & $statementMs)
  if lockMs > 0:
    statements.add("set lock_timeout = " & $lockMs)
  if idleMs > 0:
    statements.add("set idle_in_transaction_session_timeout = " & $idleMs)
  if statements.len == 0:
    return
  let res = pqexec(conn, statements.join("; ").cstring)
  if res == nil:
    raise newException(DbError, $pqerrorMessage(conn))
  try:
    if pqresultStatus(res) != PGRES_COMMAND_OK:
      raiseResultError(res)
  finally:
    pqclear(res)

proc openDb*(dsn: string, poolSize: int, statementTimeoutMs = 0,
             lockTimeoutMs = 0, acquireTimeoutMs = 0,
             idleTimeoutMs = 0): Db =
  ## Opens the pool. A zero bound disables that limit, which is the default:
  ## the web timeouts belong to the API process edge that reads them from its
  ## environment, not to every caller of this library. `idleTimeoutMs = 0`
  ## follows `statementTimeoutMs`, because a transaction left open holds its
  ## row locks until the connection dies.
  if poolSize < 1:
    raise newException(ValueError, "pool size must be at least 1")
  result = Db(size: poolSize)
  result.acquireTimeoutMs = acquireTimeoutMs
  result.statementTimeoutMs = statementTimeoutMs
  result.lockTimeoutMs = lockTimeoutMs
  result.idleTimeoutMs =
    if idleTimeoutMs > 0: idleTimeoutMs
    elif statementTimeoutMs > 0: statementTimeoutMs
    else: 0
  initLock(result.lock)
  initCond(result.cond)
  for _ in 0 ..< poolSize:
    let conn = pqconnectdb(dsn.cstring)
    if conn == nil or pqstatus(conn) != CONNECTION_OK:
      let detail =
        if conn == nil: "cannot allocate connection"
        else: $pqerrorMessage(conn)
      raise newException(DbError, "cannot connect to PostgreSQL: " & detail)
    try:
      configureConn(conn, result.statementTimeoutMs, result.lockTimeoutMs,
        result.idleTimeoutMs)
    except CatchableError:
      pqfinish(conn)
      raise
    result.available.add(conn)

proc close*(db: Db) =
  acquire(db.lock)
  for conn in db.available:
    pqfinish(conn)
  db.available.setLen(0)
  release(db.lock)
  deinitCond(db.cond)
  deinitLock(db.lock)

when defined(posix):
  proc pthreadCondTimedWait(cond: var Cond, lock: var Lock,
                            deadline: var Timespec): cint {.
    importc: "pthread_cond_timedwait", header: "<pthread.h>".}

  proc realtimeDeadline(timeoutMs: int): Timespec =
    ## `pthread_cond_timedwait` wants an absolute CLOCK_REALTIME instant, so
    ## the deadline is computed once and every wake compares against it. A
    ## spurious wake therefore cannot extend the wait.
    discard clock_gettime(CLOCK_REALTIME, result)
    result.tv_sec = cast[typeof(result.tv_sec)](
      int(result.tv_sec) + timeoutMs div 1000)
    result.tv_nsec = cast[typeof(result.tv_nsec)](
      int(result.tv_nsec) + (timeoutMs mod 1000) * 1_000_000)
    if int(result.tv_nsec) >= 1_000_000_000:
      result.tv_sec = cast[typeof(result.tv_sec)](int(result.tv_sec) + 1)
      result.tv_nsec = cast[typeof(result.tv_nsec)](
        int(result.tv_nsec) - 1_000_000_000)

proc acquireConn(db: Db): PPGconn =
  acquire(db.lock)
  when defined(posix):
    if db.acquireTimeoutMs > 0:
      var deadline = realtimeDeadline(db.acquireTimeoutMs)
      while db.available.len == 0:
        let rc = pthreadCondTimedWait(db.cond, db.lock, deadline)
        if db.available.len > 0:
          break
        if rc != 0:
          release(db.lock)
          raise newException(DbPoolTimeout,
            "no database connection within " & $db.acquireTimeoutMs & "ms")
    else:
      while db.available.len == 0:
        wait(db.cond, db.lock)
  else:
    while db.available.len == 0:
      wait(db.cond, db.lock)
  result = db.available.pop()
  release(db.lock)

proc connectionTimeouts*(db: Db): seq[(string, string, string)] =
  ## The effective `statement_timeout`, `lock_timeout` and
  ## `idle_in_transaction_session_timeout` of every pooled connection. The
  ## integration test reads this to prove the settings are on the connection
  ## rather than on one lucky checkout.
  acquire(db.lock)
  try:
    for conn in db.available:
      let rows = executeRows(conn,
        """select current_setting('statement_timeout') as statement_timeout,
                  current_setting('lock_timeout') as lock_timeout,
                  current_setting('idle_in_transaction_session_timeout') as idle_timeout""",
        @[])
      if rows.len > 0:
        result.add((rows[0].get("statement_timeout"),
          rows[0].get("lock_timeout"), rows[0].get("idle_timeout")))
  finally:
    release(db.lock)

proc releaseConn(db: Db, conn: PPGconn) =
  acquire(db.lock)
  db.available.add(conn)
  signal(db.cond)
  release(db.lock)

proc withConn[T](db: Db, body: proc(conn: DbConn): T): T =
  if db.pinned != nil:
    return body(DbConn(conn: db.pinned))
  let conn = acquireConn(db)
  try:
    body(DbConn(conn: conn))
  finally:
    releaseConn(db, conn)

proc boundTo*(db: Db, conn: DbConn): Db =
  ## A facade over a connection the caller already holds inside a transaction.
  ## Hand it to a helper that takes a `Db` when its statements must join the
  ## caller's transaction instead of checking out a second connection. A `tx`
  ## on the facade runs its body without `BEGIN`/`COMMIT`: the caller has
  ## already opened the boundary, and only that caller may end it.
  Db(pinned: conn.conn, size: db.size)

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

proc txRet*[T](db: Db, body: proc(conn: DbConn): T): T =
  ## Runs `body` in one transaction and returns its value. A normal return
  ## commits, any exception (a `Defect` included) rolls back. Reach for this
  ## only when the body's value is the answer; otherwise `tx` says the boundary
  ## is all that matters. On a `boundTo` facade the caller already owns the
  ## boundary, so the body runs inside a savepoint: a helper that catches its
  ## own database error still leaves the caller's transaction usable, and only
  ## the caller may commit.
  if db.pinned != nil:
    let conn = db.pinned
    savepointSeq.inc
    let name = "majadu_sp_" & $savepointSeq
    let saveRes = pqexec(conn, ("savepoint " & name).cstring)
    try:
      if pqresultStatus(saveRes) != PGRES_COMMAND_OK:
        raiseResultError(saveRes)
    finally:
      pqclear(saveRes)
    var released = false
    try:
      result = body(DbConn(conn: conn))
      let releaseRes = pqexec(conn, ("release savepoint " & name).cstring)
      try:
        if pqresultStatus(releaseRes) != PGRES_COMMAND_OK:
          raiseResultError(releaseRes)
      finally:
        pqclear(releaseRes)
      released = true
    finally:
      if not released:
        let rollbackRes = pqexec(conn, ("rollback to savepoint " & name).cstring)
        if rollbackRes != nil:
          pqclear(rollbackRes)
        let releaseRes = pqexec(conn, ("release savepoint " & name).cstring)
        if releaseRes != nil:
          pqclear(releaseRes)
    return
  withConn(db, proc(conn: DbConn): T =
    let beginRes = pqexec(conn.conn, "BEGIN")
    try:
      if pqresultStatus(beginRes) != PGRES_COMMAND_OK:
        raiseResultError(beginRes)
    finally:
      pqclear(beginRes)
    var committed = false
    countingStatements = true
    transactionStatements = 0
    try:
      result = body(conn)
      let commitRes = pqexec(conn.conn, "COMMIT")
      try:
        if pqresultStatus(commitRes) != PGRES_COMMAND_OK:
          raiseResultError(commitRes)
      finally:
        pqclear(commitRes)
      committed = true
    finally:
      countingStatements = false
      # Every exit path, `Defect` included, must release the transaction before
      # `withConn` hands the connection back to the pool.
      if not committed:
        let rollbackRes = pqexec(conn.conn, "ROLLBACK")
        if rollbackRes != nil:
          pqclear(rollbackRes)
  )

proc tx*(db: Db, body: proc(conn: DbConn)) =
  ## Runs `body` in one transaction. A normal return commits, an exception rolls
  ## back. There is no "return without committing": a refusal that must not land
  ## decides before the first write and raises, so a caller cannot mistake the
  ## end of the body for a commit it did not ask for.
  discard txRet(db, proc(conn: DbConn): bool =
    body(conn)
    true)
