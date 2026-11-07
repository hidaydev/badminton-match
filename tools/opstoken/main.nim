import std/[json, options, os, strutils]
import cli
import db/db
import account/domain/audit
import account/infrastructure/audit_store
import account/infrastructure/ops_token

const
  program = "opstoken"
  usage = """Usage: opstoken <create|list|revoke> [options]

  create --name <label> [--sub <google-sub>] [--days N]
      Print a new bearer token once. --sub records the acting owner and an
      audit row; --days 0 means no expiry.
  list
      Show tokens (id, name, created, expiry, revocation) without secrets.
  revoke --id <token-id>

Requires MAJADU_PG_DSN."""

proc main() =
  if paramCount() < 1:
    echo usage
    quit(2)
  let command = paramStr(1)
  var name = ""
  var sub = ""
  var tokenId = ""
  var days = 30
  for (flag, value) in flags(program, 2, ["--name", "--sub", "--days", "--id"]):
    case flag
    of "--name":
      name = value
    of "--sub":
      sub = value
    of "--days":
      try:
        days = parseInt(value)
      except ValueError:
        fail(program, "--days is not a number: " & value)
    of "--id":
      tokenId = value
    else:
      usageFail(program, "unknown argument: " & flag)

  let db = openDb(dsnOrFail(program), 1)
  defer: db.close()

  case command
  of "create":
    if name.len == 0:
      usageFail(program, "create needs --name")
    var actorId = ""
    if sub.len > 0:
      let row = db.queryOne(
        "select id, is_platform_owner from platform.user where google_sub = $1",
        @[textParam(sub)])
      if row.isNone:
        fail(program, "no user with sub " & sub)
      if row.get.get("is_platform_owner") != "t":
        fail(program, "only a platform owner may issue ops tokens")
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
      usageFail(program, "revoke needs --id")
    if ops_token.revokeToken(db, tokenId):
      echo $(%*{"revoked": tokenId})
    else:
      fail(program, "token not found or already revoked")
  else:
    usageFail(program, "unknown command: " & command)

when isMainModule:
  main()
