import std/[options, os, unittest]
import db/db
import ../../audit_retention

proc dsn(): string = getEnv("MAJADU_PG_DSN")

const markerAction = "test.append_only"

proc insertRow(db: Db, ageDays: int): string =
  let row = db.queryOne(
    """insert into account.audit
         (occurred_at, actor_role, action, target_kind, target_id, result,
          request_id)
       values (now() - make_interval(days => $1), 'admin', $2, 'player',
               'target-1', 'allow', 'req-1')
       returning id""",
    @[intParam(ageDays.int64), textParam(markerAction)])
  row.get.get("id")

suite "account.audit append-only":
  var db: Db

  setup:
    if dsn().len == 0:
      raise newException(ValueError, "MAJADU_PG_DSN is required")
    db = openDb(dsn(), 1)

  teardown:
    db.close()

  test "the owner role cannot update an audit row":
    discard insertRow(db, 1)
    var failed = false
    try:
      discard db.execUpdate(
        "update account.audit set action = 'tampered' where action = $1",
        @[textParam(markerAction)])
    except DbError as error:
      failed = error.sqlState == "55000"
    check failed

  test "the owner role cannot delete an audit row outside maintenance":
    discard insertRow(db, 1)
    var failed = false
    try:
      discard db.execUpdate(
        "delete from account.audit where action = $1",
        @[textParam(markerAction)])
    except DbError as error:
      failed = error.sqlState == "55000"
    check failed

  test "the application role has no UPDATE or DELETE grant":
    let row = db.queryOne(
      """select has_table_privilege('bm2_app', 'account.audit', 'UPDATE')
                or has_table_privilege('bm2_app', 'account.audit', 'DELETE')
                as allowed
         where exists (select 1 from pg_roles where rolname = 'bm2_app')""")
    if row.isSome:
      check row.get.get("allowed") == "f"

  test "the retention path prunes inside its maintenance transaction":
    let id = insertRow(db, 400)
    let removed = purgeAudit(db, 365)
    check removed >= 1
    let left = db.queryOne(
      "select 1 as present from account.audit where id = $1::uuid",
      @[textParam(id)])
    check left.isNone

  test "a fresh row survives the retention path":
    let id = insertRow(db, 1)
    discard purgeAudit(db, 365)
    let left = db.queryOne(
      "select 1 as present from account.audit where id = $1::uuid",
      @[textParam(id)])
    check left.isSome
    # The row is still append-only after the purge committed: the opt-in was
    # local to the purge transaction.
    var failed = false
    try:
      discard db.execUpdate("delete from account.audit where id = $1::uuid",
        @[textParam(id)])
    except DbError as error:
      failed = error.sqlState == "55000"
    check failed
