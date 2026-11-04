import std/[json, options, os]
import db/db
import account/infrastructure/lifecycle_store

const usage = """Usage: accountlifecycle anonymize --sub <google-sub> --actor <actor-sub>
                              [--reason <text>]

Closes the account's claims, unlinks its players, drops its sessions and rewrites
the identity so the subject can never sign in again. Rating rows stay.

Requires MAJADU_PG_DSN."""

proc fail(message: string) {.noreturn.} =
  stderr.writeLine "accountlifecycle: " & message
  quit(2)

proc userIdOf(db: Db, sub: string): string =
  let row = db.queryOne(
    "select id from platform.user where google_sub = $1", @[textParam(sub)])
  if row.isNone:
    fail "no user with sub " & sub
  row.get.get("id")

proc main() =
  if paramCount() < 1 or paramStr(1) != "anonymize":
    echo usage
    quit(2)
  var sub = ""
  var actorSub = ""
  var reason = "account_anonymized"
  var index = 2
  while index <= paramCount():
    case paramStr(index)
    of "--sub":
      index.inc; sub = paramStr(index)
    of "--actor":
      index.inc; actorSub = paramStr(index)
    of "--reason":
      index.inc; reason = paramStr(index)
    else:
      fail "unknown argument: " & paramStr(index)
    index.inc
  if sub.len == 0 or actorSub.len == 0:
    fail "anonymize needs --sub and --actor"
  let dsn = getEnv("MAJADU_PG_DSN")
  if dsn.len == 0:
    fail "MAJADU_PG_DSN is required"
  let db = openDb(dsn, 1)
  defer: db.close()
  let outcome = anonymize(db, userIdOf(db, sub), userIdOf(db, actorSub), reason)
  if outcome != lrOk:
    fail $outcome
  echo $(%*{"anonymized": sub})

when isMainModule:
  main()
