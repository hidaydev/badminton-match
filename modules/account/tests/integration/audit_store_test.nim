## The audit writer's columns, its sanitiser and its append-only grant.
##
## `account.audit` is shared and append-only, so every read here filters on a
## request id this run minted and nothing is ever deleted. The owner bootstrap
## case runs against its own database because `ownerseed` refuses a second owner
## and its audit row must outlive the process.

import std/[json, options, os, osproc, strutils, unittest]
import db/db
import tests/fixtures
import ../../domain/audit
import ../../infrastructure/audit_store
import ../../../../tools/dbtools/main

const
  migrationsDir = "db/migrations"
  seedsDir = "db/seeds"
  ownerseedSource = "tools/ownerseed/main.nim"

proc requestId(): string =
  "be12-audit-" & $getCurrentProcessId()

proc databaseDsn(dsn, database: string): string =
  let query = dsn.find('?')
  let head = if query >= 0: dsn[0 ..< query] else: dsn
  let tail = if query >= 0: dsn[query .. ^1] else: ""
  let slash = head.rfind('/')
  if slash <= head.find("://") + 2:
    raise newException(ValueError, "MAJADU_PG_DSN has no database path: " & dsn)
  head[0 ..< slash] & "/" & database & tail

proc adminDsn(): string =
  let explicit = getEnv("MAJADU_PG_ADMIN_DSN")
  if explicit.len > 0:
    return explicit
  databaseDsn(getEnv("MAJADU_PG_DSN"), "postgres")

proc checkedName(name: string): string =
  for character in name:
    if character notin {'a' .. 'z', '0' .. '9', '_'}:
      raise newException(ValueError, "unsafe database name: " & name)
  name

proc expectPermissionDenied(db: Db, statement: string,
                            request: string): string =
  ## `set local role` keeps the application role inside one transaction, so a
  ## refused statement cannot leak the downgraded role into the pool.
  try:
    db.tx(proc(conn: DbConn) =
      discard conn.execUpdate("set local role bm2_app")
      discard conn.execUpdate(statement, @[textParam(request)]))
  except DbError as error:
    return error.sqlState
  ""

suite "audit store":
  var db: Db
  var userId: string
  var communityId: string
  var fixtureNo = 0
  let request = requestId()

  setup:
    if getEnv("MAJADU_PG_DSN").len == 0:
      raise newException(ValueError, "MAJADU_PG_DSN is required")
    db = openDb(getEnv("MAJADU_PG_DSN"), 1)
    inc fixtureNo
    let suffix = $getCurrentProcessId() & "-" & $fixtureNo
    communityId = newCommunity(db, "be12-audit-" & suffix, "Audit fixture")
    userId = newUser(db, "be12-audit-" & suffix,
      "be12-audit-" & suffix & "@example.com", "Auditor")

  teardown:
    db.close()

  test "recordAudit maps every column and sanitises the evidence":
    recordAudit(db, AuditEvent(
      actorId: userId, actorRole: "admin", communityId: communityId,
      action: "be12.mapped", targetKind: "player", targetId: "target-1",
      result: arDeny, reason: "review", requestId: request,
      before: %*{"name": "Old", "role": "member", "count": 2},
      after: %*{"name": "New", "email": "secret@example.com",
                "shareCode": "abc", "ticket": "t", "nested": {"a": 1},
                "list": [1, 2]}))

    let row = db.queryOne(
      """select actor_id::text as actor_id, actor_role, community_id::text as community_id,
                action, target_kind, target_id, result, reason, request_id,
                before::text as before, after::text as after
         from account.audit where request_id = $1""",
      @[textParam(request)]).get
    check row.getUuid("actor_id") == userId
    check row.get("actor_role") == "admin"
    check row.getUuid("community_id") == communityId
    check row.get("action") == "be12.mapped"
    check row.get("target_kind") == "player"
    check row.get("target_id") == "target-1"
    check row.get("result") == "deny"
    check row.get("reason") == "review"
    check row.get("request_id") == request
    check parseJson(row.get("before")) ==
      %*{"name": "Old", "role": "member", "count": 2}
    let after = parseJson(row.get("after"))
    check after == %*{"name": "New"}
    for key in ["email", "shareCode", "ticket", "nested", "list"]:
      check not after.hasKey(key)

  test "an empty role becomes member and an empty request id becomes a dash":
    let marker = request & "-defaults"
    # The factory always supplies an object; a bare `AuditEvent` leaves the
    # evidence nil, which the writer's drop report cannot walk.
    recordAudit(db, AuditEvent(action: "be12.defaults", requestId: marker,
      result: arAllow, targetKind: "user", targetId: marker,
      before: newJObject(), after: newJObject()))
    let row = db.queryOne(
      """select actor_role, request_id, target_id from account.audit
         where request_id = $1""", @[textParam(marker)]).get
    check row.get("actor_role") == "member"
    check row.get("request_id") == marker
    # A separate empty request id cannot be filtered by value, so the writer is
    # asked for its own default through a row the action uniquely names.
    recordAudit(db, AuditEvent(action: "be12.dash", requestId: "",
      result: arAllow, targetKind: "user", targetId: marker,
      before: newJObject(), after: newJObject()))
    let dashed = db.queryOne(
      """select request_id from account.audit
         where action = 'be12.dash' and target_id = $1""",
      @[textParam(marker)]).get
    check dashed.get("request_id") == "-"

  test "a null actor and community are stored as SQL NULL":
    let marker = request & "-nulls"
    recordAudit(db, AuditEvent(action: "be12.nulls", requestId: marker,
      result: arError, targetKind: "platform", targetId: marker,
      before: newJObject(), after: newJObject()))
    let row = db.queryOne(
      """select actor_id, community_id from account.audit
         where request_id = $1""", @[textParam(marker)]).get
    check row["actor_id"].isNone
    check row["community_id"].isNone

  test "the application role cannot update or delete an audit row":
    let marker = request & "-grant"
    recordAudit(db, AuditEvent(action: "be12.grant", requestId: marker,
      result: arAllow, targetKind: "user", targetId: marker,
      before: newJObject(), after: newJObject()))

    let updateState = expectPermissionDenied(db,
      "update account.audit set reason = 'rewritten' where request_id = $1",
      marker)
    check updateState == "42501"

    let deleteState = expectPermissionDenied(db,
      "delete from account.audit where request_id = $1", marker)
    check deleteState == "42501"

    let row = db.queryOne(
      """select reason from account.audit where request_id = $1""",
      @[textParam(marker)]).get
    check row["reason"].isNone

suite "ownerseed audit row":
  test "the first run records one bootstrap row and the second records none":
    let originalDsn = getEnv("MAJADU_PG_DSN")
    if originalDsn.len == 0:
      raise newException(ValueError, "MAJADU_PG_DSN is required")
    let scratchName = checkedName("bm2_audit_" & $getCurrentProcessId())
    let binary = getTempDir() / ("be12-ownerseed-" & $getCurrentProcessId())
    let cache = getTempDir() / ("be12-ownerseed-cache-" &
      $getCurrentProcessId())
    let admin = openDb(adminDsn(), 1)
    var scratch: Db = nil
    try:
      discard admin.execUpdate("drop database if exists " & scratchName &
        " with (force)")
      discard admin.execUpdate("create database " & scratchName)
      let scratchDsn = databaseDsn(originalDsn, scratchName)
      scratch = openDb(scratchDsn, 1)
      migrate(scratch, migrationsDir)
      seed(scratch, seedsDir)

      let (buildOutput, buildCode) = execCmdEx(
        "nim c --hints:off --nimcache:" & quoteShell(cache) &
        " -o:" & quoteShell(binary) & " " & quoteShell(ownerseedSource))
      check buildCode == 0
      if buildCode == 0:
        let sub = "be12-owner-" & $getCurrentProcessId()
        putEnv("MAJADU_PG_DSN", scratchDsn)
        try:
          let first = execCmdEx(quoteShell(binary) & " --sub " &
            quoteShell(sub) & " --email be12-owner@example.com")
          check first.exitCode == 0
          if first.exitCode == 0:
            let row = scratch.queryOne(
              """select actor_role, request_id, target_kind, after::text as after
                 from account.audit
                 where action = 'platform.owner.bootstrap'""").get
            check row.get("actor_role") == "platform_owner"
            check row.get("request_id") == "cli"
            check row.get("target_kind") == "user"
            check parseJson(row.get("after")) == %*{"role": "platform_owner"}
            let total = scratch.queryOne(
              """select count(*)::int as total from account.audit
                 where action = 'platform.owner.bootstrap'""").get
            check total.getInt("total") == 1

            let second = execCmdEx(quoteShell(binary) & " --sub " &
              quoteShell(sub) & " --email be12-owner@example.com")
            check second.exitCode == 0
            let again = scratch.queryOne(
              """select count(*)::int as total from account.audit
                 where action = 'platform.owner.bootstrap'""").get
            check again.getInt("total") == 1
          else:
            checkpoint(first.output)
        finally:
          putEnv("MAJADU_PG_DSN", originalDsn)
      else:
        checkpoint(buildOutput)
    finally:
      if scratch != nil:
        scratch.close()
      discard admin.execUpdate("drop database if exists " & scratchName &
        " with (force)")
      admin.close()
      if fileExists(binary):
        removeFile(binary)