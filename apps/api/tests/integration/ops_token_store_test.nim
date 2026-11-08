## The ops-token store cases the HTTP suite does not reach: a token with no
## expiry, a revoke that succeeds once, and the list order. Rows are scoped by
## the name prefix this run minted, never by deleting the table.

import std/[options, os, strutils, unittest]
import db/db
import account/infrastructure/ops_token

var
  database: Db
  prefix: string

proc runTag(): string = $getCurrentProcessId()

proc bootstrap() =
  if getEnv("MAJADU_PG_DSN").len == 0:
    raise newException(ValueError, "MAJADU_PG_DSN is required")
  prefix = "be12-ops-" & runTag() & "-"
  database = openDb(getEnv("MAJADU_PG_DSN"), 1)
  discard database.execUpdate(
    "delete from platform.ops_token where name like $1",
    @[textParam(prefix & "%")])

bootstrap()

suite "ops token store":
  test "a zero-day token stores a NULL expiry and still verifies":
    let token = issue(database, prefix & "no-expiry", "", 0)
    let row = database.queryOne(
      """select expires_at, encode(token_hash, 'hex') as token_hash
         from platform.ops_token where name = $1""",
      @[textParam(prefix & "no-expiry")]).get
    check row["expires_at"].isNone
    check row.get("token_hash").len == 64
    check verify(database, token) == some(prefix & "no-expiry")
    check verify(database, token & "0").isNone
    check verify(database, "").isNone

  test "revokeToken returns true once and false on the second call":
    discard issue(database, prefix & "revoke", "", 30)
    let id = database.queryOne(
      "select id from platform.ops_token where name = $1",
      @[textParam(prefix & "revoke")]).get.getUuid("id")
    check revokeToken(database, id)
    check not revokeToken(database, id)
    let row = database.queryOne(
      "select revoked_at from platform.ops_token where id = $1::uuid",
      @[textParam(id)]).get
    check row["revoked_at"].isSome

  test "list orders newest first":
    for index in 0 .. 2:
      discard issue(database, prefix & "order-" & $index, "", 30)
    # Pin the timestamps so the order is the statement's, not the clock's.
    discard database.execUpdate(
      """update platform.ops_token set created_at = now() - interval '3 hours'
         where name = $1""", @[textParam(prefix & "order-0")])
    discard database.execUpdate(
      """update platform.ops_token set created_at = now() - interval '2 hours'
         where name = $1""", @[textParam(prefix & "order-1")])
    discard database.execUpdate(
      """update platform.ops_token set created_at = now() - interval '1 hour'
         where name = $1""", @[textParam(prefix & "order-2")])
    var ours: seq[string] = @[]
    for row in list(database):
      if row.name.startsWith(prefix & "order-"):
        ours.add(row.name)
    check ours.len == 3
    check ours[0] == prefix & "order-2"
    check ours[1] == prefix & "order-1"
    check ours[2] == prefix & "order-0"

discard database.execUpdate(
  "delete from platform.ops_token where name like $1",
  @[textParam(prefix & "%")])
database.close()