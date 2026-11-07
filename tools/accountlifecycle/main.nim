import std/[json, options, os]
import cli
import db/db
import account/infrastructure/lifecycle_store

const
  program = "accountlifecycle"
  usage = """Usage: accountlifecycle anonymize --sub <google-sub> --actor <actor-sub>
                              [--reason <text>]

Closes the account's claims, unlinks its players, drops its sessions and rewrites
the identity so the subject can never sign in again. Rating rows stay.

Requires MAJADU_PG_DSN."""

proc userIdOf(db: Db, sub: string): string =
  let row = db.queryOne(
    "select id from platform.user where google_sub = $1", @[textParam(sub)])
  if row.isNone:
    fail(program, "no user with sub " & sub)
  row.get.get("id")

proc main() =
  if paramCount() < 1 or paramStr(1) != "anonymize":
    echo usage
    quit(2)
  var sub = ""
  var actorSub = ""
  var reason = "account_anonymized"
  for (flag, value) in flags(program, 2, ["--sub", "--actor", "--reason"]):
    case flag
    of "--sub":
      sub = value
    of "--actor":
      actorSub = value
    of "--reason":
      reason = value
    else:
      usageFail(program, "unknown argument: " & flag)
  if sub.len == 0 or actorSub.len == 0:
    usageFail(program, "anonymize needs --sub and --actor")
  let db = openDb(dsnOrFail(program), 1)
  defer: db.close()
  let outcome = anonymize(db, userIdOf(db, sub), userIdOf(db, actorSub), reason)
  if outcome != lrOk:
    fail(program, $outcome)
  echo $(%*{"anonymized": sub})

when isMainModule:
  main()
