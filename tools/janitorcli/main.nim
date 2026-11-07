import std/json
import cli
import db/db
import platform/config/store
import platform/janitor

const program = "janitor"

proc main() =
  let db = openDb(dsnOrFail(program), 1)
  defer: db.close()
  let days = loadSnapshot(db).intValue(%*{}, keyJanitorRetentionDays)
  var rows = newJArray()
  var total = 0
  for outcome in purge(db, days):
    rows.add(%*{"table": outcome.table, "deleted": outcome.deleted})
    total += outcome.deleted
  echo $(%*{"retentionDays": days, "deleted": total, "tables": rows})

when isMainModule:
  main()
