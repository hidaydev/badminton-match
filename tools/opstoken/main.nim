import std/[json, options, os, strutils]
import db/db
import account/domain/audit
import account/infrastructure/audit_store
import account/infrastructure/ops_token

const usage = """Usage: opstoken <create|list|revoke> [options]

  create --name <label> [--sub <google-sub>] [--days N]
      Print a new bearer token once. --sub records the acting owner and an
      audit row; --days 0 means no expiry.
  list
      Show tokens (id, name, created, expiry, revocation) without secrets.
  revoke --id <token-id>

Requires MAJADU_PG_DSN."""

proc fail(message: string) {.noreturn.} =
  stderr.writeLine "opstoken: " & message
  quit(2)

proc main() =
  if paramCount() < 1:
    echo usage
    quit(2)
  let command = paramStr(1)
  var name = ""
  var sub = ""
  var tokenId = ""
  var days = 30
  var index = 2
  while index <= paramCount():
    case paramStr(index)
    of "--name":
      index.inc; name = paramStr(index)
    of "--sub":
      index.inc; sub = paramStr(index)
    of "--days":
      index.inc; days = parseInt(paramStr(index))
    of "--id":
      index.inc; tokenId = paramStr(index)
    else:
      fail "unknown argument: " & paramStr(index)
    index.inc

  let dsn = getEnv("MAJADU_PG_DSN")
  if dsn.len == 0:
    fail "MAJADU_PG_DSN is required"
  let db = openDb(dsn, 1)
  defer: db.close()

  case command
  of "create":
    if name.len == 0:
      fail "create needs --name"
    var actorId = ""
    if sub.len > 0:
      let row = db.queryOne(
        "select id, is_platform_owner from platform.user where google_sub = $1",
        @[textParam(sub)])
      if row.isNone:
        fail "no user with sub " & sub
      if row.get.get("is_platform_owner") != "t":
        fail "only a platform owner may issue ops tokens"
      actorId = row.get.get("id")
    let token = ops_token.issue(db, name, actorId, days)
    if actorId.len > 0:
      recordAudit(db, auditEvent("platform.ops_token.create", communityId = "",
        actorId = actorId, actorRole = "platform_owner",
        targetKind = "ops_token", targetId = name,
        requestId = "cli").withEvidence(newJObject(), %*{"name": name}))
    echo $(%*{"token": token, "name": name, "expiresInDays": days})
  of "list":
    var items = newJArray()
    for entry in ops_token.list(db):
      items.add(%*{"id": entry.id, "name": entry.name,
        "createdAt": entry.createdAt, "expiresAt": entry.expiresAt,
        "revokedAt": entry.revokedAt})
    echo $(%*{"items": items})
  of "revoke":
    if tokenId.len == 0:
      fail "revoke needs --id"
    if ops_token.revokeToken(db, tokenId):
      echo $(%*{"revoked": tokenId})
    else:
      fail "token not found or already revoked"
  else:
    fail "unknown command: " & command

when isMainModule:
  main()
