import std/[locks, options, strutils, tables, times]
when defined(posix):
  import std/posix
import std/atomics
import db_connector/postgres

type
  DbParamKind* = enum
    dpNull, dpText, dpInt, dpBool, dpTimestamp, dpBytea

  DbParam* = object
    case kind*: DbParamKind
    of dpNull: discard
    of dpText: text*: string
    of dpInt: intValue*: int64
    of dpBool: boolValue*: bool
    of dpTimestamp: timestampValue*: string
    ## Raw bytes, sent in binary format so the server takes them as the `bytea`
    ## value itself. A hex string sent as text resolves to the `bytea` overload
    ## too, but arrives as 64 ASCII characters instead of 32 bytes, and a
    ## comparison against a column of hashes then never matches.
    of dpBytea: bytes*: seq[byte]

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
    ## The DSN the pool was opened with. A connection libpq reports as dead is
    ## replaced from it, so the pool never hands back a handle whose socket a
    ## server restart closed.
    dsn: string
    ## Set only on a facade built by `boundTo`: the connection the caller is
    ## already inside a transaction with. Such a facade never takes a pooled
    ## connection and never opens a transaction of its own.
    pinned: PPGconn
    ## Set on a facade built by `scoped` and by `boundTo` on one: the community
    ## every statement on this facade declares to the database. Empty means the
    ## facade declares none, which is what an unscoped caller gets.
    scopedCommunity: string
    ## Set on a facade: the pool it borrows from. A facade owns no connections,
    ## so it cannot own a lock either; every checkout goes through this.
    root: Db
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
  ## The setting the tenant policy set reads. `session.tenant_id()` turns the
  ## empty string into NULL, which matches no tenant, so a facade that declares
  ## no community is a facade the database sees as outside every community.
  tenantSetting* = "majadu.community_id"
  ## One statement per checkout, deliberately not counted: the statement counter
  ## is a contract on what the application reads and writes, and a session
  ## setting is transport for the statement that follows it.
  tenantStatement = "select set_config('" & tenantSetting & "', $1, false)"
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

proc byteaParam*(value: openArray[byte]): DbParam =
  ## The bytes themselves, not their hex. `sha256Raw` feeds it directly: a hash
  ## passed as hex is 64 characters the server stores as a 64-byte `bytea`, and
  ## `code_hash = $1` then compares 32 bytes against 64.
  DbParam(kind: dpBytea, bytes: @value)

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
  of dpNull: result = ""
  of dpText: result = param.text
  of dpInt: result = $param.intValue
  of dpBool: result = (if param.boolValue: "true" else: "false")
  of dpTimestamp: result = param.timestampValue
  of dpBytea:
    # Only a fallback: a `dpBytea` value goes on the wire in binary. Text form is
    # the hex a `decode($1,'hex')` call site expects.
    result = newStringOfCap(param.bytes.len * 2)
    for value in param.bytes:
      result.add(toHex(value, 2))

proc errorField(res: PPGresult, code: cint): string =
  let value = pqresultErrorField(res, code)
  if value == nil: "" else: $value

proc raiseResultError(res: PPGresult) {.noreturn.} =
  var error = newException(DbError, $pqresultErrorMessage(res))
  error.sqlState = errorField(res, PG_DIAG_SQLSTATE)
  error.constraint = errorField(res, PG_DIAG_CONSTRAINT_NAME)
  raise error

var
  # The statement counter is a test hook: a suite proves that a batched write
  # costs a fixed number of round trips instead of one per row. Only a
  # transaction's own statements are counted, because its body is what a write
  # holds its row locks for; `BEGIN`/`COMMIT` never reach the executors.
  countingStatements {.threadvar.}: bool
  transactionStatements {.threadvar.}: int
  savepointSeq {.threadvar.}: int
  # Every statement the process has issued, across threads. A read route cannot
  # use `statementsInTransaction` (it opens no transaction) and a suite cannot
  # read a threadvar of the worker thread that served the request, so the read
  # side is counted process-wide.
  statementsAll: Atomic[int]
  # Rows the driver materialised, likewise process-wide. A statement count
  # cannot tell a board-wide read from a one-row read (both are one statement),
  # so the suites that prove a detail route stays narrow count rows instead.
  rowsAll: Atomic[int]
  # Opt-in statement log. A suite turns it on, sends one request and counts the
  # statements by text, which is how a request-cost contract (one config version
  # probe, one settings read) is proven. Every other process leaves it off, so
  # the cost is one atomic load per statement.
  recordingStatements: Atomic[bool]
  statementLog = initTable[string, int]()
  statementLogLock: Lock

initLock(statementLogLock)

proc resultToRows(res: PPGresult): seq[Row] =
  let columns = pqnfields(res)
  let rows = pqntuples(res)
  if rows > 0:
    discard rowsAll.fetchAdd(rows)
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
  ## Owns the bytes of every `dpBytea` parameter. Empty when no parameter is
  ## binary, which keeps the all-text path exactly as it was.
  raw: seq[seq[byte]]
  ## One entry per parameter, allocated only when at least one is binary:
  ## libpq reads both arrays for every parameter once either is supplied.
  lengths: ptr UncheckedArray[int32]
  formats: ptr UncheckedArray[int32]

proc countStatement(sql: string) =
  discard statementsAll.fetchAdd(1)
  if countingStatements:
    inc transactionStatements
  if recordingStatements.load(moRelaxed):
    acquire(statementLogLock)
    try:
      let key = sql.strip()
      statementLog[key] = statementLog.getOrDefault(key) + 1
    finally:
      release(statementLogLock)

proc recordStatements*(on: bool) =
  ## Test hook: clears the log and starts or stops recording. A suite turns it
  ## on around one request, so the count it asserts is that request's rather
  ## than the process's.
  acquire(statementLogLock)
  try:
    statementLog.clear()
  finally:
    release(statementLogLock)
  recordingStatements.store(on, moRelaxed)

proc statementsMatching*(needle: string): int =
  ## Recorded statements whose text contains `needle`, since the last
  ## `recordStatements(true)`. Zero in a process that never enabled the log.
  acquire(statementLogLock)
  try:
    for sql, count in statementLog.pairs:
      if needle in sql:
        result += count
  finally:
    release(statementLogLock)

proc statementsIssued*(): int =
  ## Statements executed since the process started, over every thread. A suite
  ## reads the delta around one call to prove a read costs a fixed number of
  ## round trips regardless of how many rows it returns.
  statementsAll.load()

proc rowsReturned*(): int =
  ## Rows returned to the driver since the process started, over every thread.
  ## A suite reads the delta around one call to prove a detail read fetches one
  ## row instead of materialising the whole board.
  rowsAll.load()

proc statementsInTransaction*(): int =
  ## How many statements the most recent transaction sent, `BEGIN`/`COMMIT`
  ## excluded. The suites read it to keep a batched write from growing with its
  ## row count.
  transactionStatements

proc measureStatements*(body: proc()): int =
  ## Test hook: statements `body` sends, whatever connections it checks out.
  ## A read that costs one statement per row must fail this without wrapping the
  ## body in a transaction, which would change which connection it uses.
  countingStatements = true
  transactionStatements = 0
  try:
    body()
    transactionStatements
  finally:
    countingStatements = false

proc bindValues(params: seq[DbParam]): BoundParams =
  result.values = cast[cstringArray](alloc0(params.len * sizeof(cstring)))
  result.backing = newSeq[string](params.len)
  result.raw = newSeq[seq[byte]](params.len)
  var binary = false
  for i, param in params:
    case param.kind
    of dpNull: discard
    of dpBytea:
      binary = true
      result.raw[i] = param.bytes
      # A zero-length `bytea` still needs a pointer libpq may read: a nil entry
      # is the wire encoding of NULL, not of the empty value.
      if result.raw[i].len == 0:
        result.raw[i] = newSeq[byte](1)
      result.values[i] = cast[cstring](addr result.raw[i][0])
    else:
      result.backing[i] = param.asText
      result.values[i] = result.backing[i].cstring
  if binary:
    # libpq reads both arrays entry by entry once either is supplied, and an
    # entry of zero means "text, untyped", which is what every other parameter
    # stays.
    result.lengths = cast[ptr UncheckedArray[int32]](
      alloc0(params.len * sizeof(int32)))
    result.formats = cast[ptr UncheckedArray[int32]](
      alloc0(params.len * sizeof(int32)))
    for i, param in params:
      if param.kind == dpBytea:
        result.lengths[i] = param.bytes.len.int32
        result.formats[i] = 1

proc freeValues(bound: BoundParams) =
  let count = bound.backing.len
  for i in 0 ..< count:
    bound.values[i] = nil
  dealloc(bound.values)
  if bound.lengths != nil:
    dealloc(bound.lengths)
  if bound.formats != nil:
    dealloc(bound.formats)
  # Keep the backing storage alive past the libpq call explicitly.
  discard bound.backing.len
  discard bound.raw.len

proc executeRows(conn: PPGconn, sql: string, params: seq[DbParam]): seq[Row] =
  ## The SQL string is passed verbatim with $1..$n placeholders, so a jsonb `?`
  ## operator is never rewritten or rejected.
  countStatement(sql)
  let bound = bindValues(params)
  try:
    let res = pqexecParams(
      conn, sql.cstring, params.len.int32, nil, bound.values,
      cast[ptr int32](bound.lengths), cast[ptr int32](bound.formats), 0)
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
  countStatement(sql)
  let bound = bindValues(params)
  try:
    let res = pqexecParams(
      conn, sql.cstring, params.len.int32, nil, bound.values,
      cast[ptr int32](bound.lengths), cast[ptr int32](bound.formats), 0)
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
  countStatement(sql)
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

proc connectConfigured(dsn: string, statementMs, lockMs, idleMs: int): PPGconn =
  ## One live connection with its session bounds applied. The pool is built from
  ## this and rebuilds a handle from it when libpq reports one dead.
  result = pqconnectdb(dsn.cstring)
  if result == nil or pqstatus(result) != CONNECTION_OK:
    let detail =
      if result == nil: "cannot allocate connection"
      else: $pqerrorMessage(result)
    if result != nil:
      pqfinish(result)
    raise newException(DbError, "cannot connect to PostgreSQL: " & detail)
  try:
    configureConn(result, statementMs, lockMs, idleMs)
  except CatchableError:
    pqfinish(result)
    raise

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
  result.dsn = dsn
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
    result.available.add(connectConfigured(dsn, result.statementTimeoutMs,
      result.lockTimeoutMs, result.idleTimeoutMs))

proc poolOf(db: Db): Db =
  ## The pool a facade borrows from. A facade built by `scoped` or `boundTo`
  ## owns no lock and no connections, so `close`, `poolStats` and
  ## `connectionTimeouts` must answer about the pool behind it.
  if db.root != nil: db.root else: db

proc close*(db: Db) =
  let pool = poolOf(db)
  acquire(pool.lock)
  for conn in pool.available:
    pqfinish(conn)
  pool.available.setLen(0)
  release(pool.lock)
  deinitCond(pool.cond)
  deinitLock(pool.lock)

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

proc revalidatedConn(db: Db, conn: PPGconn): Option[PPGconn] =
  ## A pooled handle is only trusted after its status is read: a PostgreSQL
  ## restart or failover closes every socket underneath the pool, and handing
  ## that fd back used to fail every route until the API was restarted. A reset
  ## reuses the handle; a handle the server still refuses is dropped and rebuilt
  ## from the same DSN. `none` means the server is unreachable right now.
  if pqstatus(conn) == CONNECTION_OK:
    return some(conn)
  pqreset(conn)
  if pqstatus(conn) == CONNECTION_OK:
    try:
      # A reset opens a new session, so the bounds `configureConn` applied to
      # the old one are gone; re-applying them is what keeps a reset connection
      # from running unbounded.
      configureConn(conn, db.statementTimeoutMs, db.lockTimeoutMs,
        db.idleTimeoutMs)
      return some(conn)
    except DbError:
      discard
  try:
    result = some(connectConfigured(db.dsn, db.statementTimeoutMs,
      db.lockTimeoutMs, db.idleTimeoutMs))
  except DbError:
    result = none(PPGconn)

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
  let checkedOut = db.available.pop()
  release(db.lock)
  # Revalidation runs outside the lock: a `PQreset` on a server that is still
  # down blocks for its whole connect timeout, and holding the pool lock across
  # it would stop every other caller from even reaching their own deadline.
  let live = revalidatedConn(db, checkedOut)
  if live.isNone:
    # The handle stays allocated and goes back, so an outage can neither hand
    # back a dead socket nor shrink the pool by one connection per attempt.
    acquire(db.lock)
    db.available.add(checkedOut)
    signal(db.cond)
    release(db.lock)
    raise newException(DbError, "cannot restore a pooled PostgreSQL connection")
  if live.get != checkedOut:
    pqfinish(checkedOut)
  result = live.get

proc poolStats*(db: Db): tuple[size, available, inUse: int] =
  ## The pool's state for the metrics gauge. `available` is what a checkout can
  ## take right now; `inUse` is size minus that, which is also what a waiting
  ## caller is queued behind once it reaches zero.
  let pool = poolOf(db)
  acquire(pool.lock)
  try:
    result.size = pool.size
    result.available = pool.available.len
  finally:
    release(pool.lock)
  result.inUse = result.size - result.available

proc connectionTimeouts*(db: Db): seq[(string, string, string)] =
  ## The effective `statement_timeout`, `lock_timeout` and
  ## `idle_in_transaction_session_timeout` of every pooled connection. The
  ## integration test reads this to prove the settings are on the connection
  ## rather than on one lucky checkout.
  let pool = poolOf(db)
  acquire(pool.lock)
  try:
    for conn in pool.available:
      let rows = executeRows(conn,
        """select current_setting('statement_timeout') as statement_timeout,
                  current_setting('lock_timeout') as lock_timeout,
                  current_setting('idle_in_transaction_session_timeout') as idle_timeout""",
        @[])
      if rows.len > 0:
        result.add((rows[0].get("statement_timeout"),
          rows[0].get("lock_timeout"), rows[0].get("idle_timeout")))
  finally:
    release(pool.lock)

proc bindTenant(conn: PPGconn, community: string) =
  ## Declares this statement's community on the connection, unconditionally.
  ##
  ## Caching what a connection already carries would be one round trip cheaper
  ## and is refused: `set_config` is transactional, so a transaction that rolls
  ## back leaves the session holding the value from before it while any cache
  ## would still claim the new one. That stale cache is a cross-tenant read, not
  ## a slow path, and it is exactly the failure the policy set exists to stop.
  ##
  ## `set_config(..., false)` is session-scoped on purpose. `is_local = true`
  ## would only apply inside an explicit transaction block, and most reads are
  ## one statement with no `BEGIN` around them. The empty string is written as
  ## an empty string: `session.tenant_id()` turns it into NULL, which matches no
  ## tenant.
  var values = [community.cstring]
  let res = pqexecParams(conn, tenantStatement.cstring, 1, nil,
    cast[cstringArray](addr values[0]), nil, nil, 0)
  if res == nil:
    raise newException(DbError, $pqerrorMessage(conn))
  try:
    if pqresultStatus(res) != PGRES_TUPLES_OK:
      raiseResultError(res)
  finally:
    pqclear(res)

proc releaseConn(db: Db, conn: PPGconn) =
  acquire(db.lock)
  db.available.add(conn)
  signal(db.cond)
  release(db.lock)

proc withConn[T](db: Db, body: proc(conn: DbConn): T): T =
  ## The one place a pooled connection is handed out. A facade with a community
  ## writes it onto the connection before `body` runs, so every statement the
  ## caller issues under the policy set is confined without the caller naming
  ## the community again.
  if db.pinned != nil:
    bindTenant(db.pinned, db.scopedCommunity)
    return body(DbConn(conn: db.pinned))
  let pool = if db.root != nil: db.root else: db
  let conn = acquireConn(pool)
  try:
    bindTenant(conn, db.scopedCommunity)
    body(DbConn(conn: conn))
  finally:
    releaseConn(pool, conn)

proc boundTo*(db: Db, conn: DbConn): Db =
  ## A facade over a connection the caller already holds inside a transaction.
  ## Hand it to a helper that takes a `Db` when its statements must join the
  ## caller's transaction instead of checking out a second connection. A `tx`
  ## on the facade runs its body without `BEGIN`/`COMMIT`: the caller has
  ## already opened the boundary, and only that caller may end it.
  ##
  ## The community of the caller's facade travels with it: a scoped read that
  ## hands a helper a connection must not lose the tenant on the way.
  Db(pinned: conn.conn, size: db.size, scopedCommunity: db.scopedCommunity,
    root: (if db.root != nil: db.root else: db))

proc scoped*(db: Db, communityId: string): Db =
  ## The same pool, with every statement on it declaring `communityId`. It owns
  ## no connection and opens no transaction, so it is cheap to build per request
  ## or per job; a statement made through it must name no other community.
  ##
  ## A facade that is already pinned to the caller's transaction stays pinned:
  ## scoping narrows what it declares, it does not move it to another connection.
  ##
  ## An empty id is refused rather than silently unscoped: a caller that meant to
  ## scope and passed nothing is a bug the database must not paper over.
  if communityId.len == 0:
    raise newException(ValueError, "scoped: community id is empty")
  Db(size: db.size, pinned: db.pinned, scopedCommunity: communityId,
    root: (if db.root != nil: db.root else: db),
    acquireTimeoutMs: db.acquireTimeoutMs,
    statementTimeoutMs: db.statementTimeoutMs,
    lockTimeoutMs: db.lockTimeoutMs, idleTimeoutMs: db.idleTimeoutMs)

proc communityOf*(db: Db): string =
  ## What this facade declares, empty when it declares nothing. The HTTP layer
  ## uses it to answer "is a tenant installed for this request" without keeping
  ## a second copy of the answer.
  db.scopedCommunity

proc query*(db: Db, sql: string, params: seq[DbParam] = @[]): seq[Row] =
  withConn(db, proc(conn: DbConn): seq[Row] = conn.query(sql, params))

proc queryOne*(db: Db, sql: string, params: seq[DbParam] = @[]): Option[Row] =
  withConn(db, proc(conn: DbConn): Option[Row] = conn.queryOne(sql, params))

proc execUpdate*(db: Db, sql: string, params: seq[DbParam] = @[]): int =
  withConn(db, proc(conn: DbConn): int = conn.execUpdate(sql, params))

proc functionExists*(db: Db, signature: string): bool =
  ## Whether a named function is installed, asked of `pg_catalog` in one round
  ## trip and deliberately not cached.
  ##
  ## The tenant helpers this answers for arrive in a later migration than the
  ## code that calls them, so the caller picks its path per call. A cached
  ## answer would be a process that started before the migration and kept
  ## reading cross-tenant after it, which is the failure mode those helpers
  ## exist to prevent.
  let row = db.queryOne(
    "select to_regprocedure($1) is not null as present",
    @[textParam(signature)])
  if row.isNone: false else: row.get.getBool("present")

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
    bindTenant(conn, db.scopedCommunity)
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
