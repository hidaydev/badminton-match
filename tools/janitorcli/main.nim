import std/[json, os]
import db/db
import platform/config/store
import platform/janitor

proc main() =
  let dsn = getEnv("MAJADU_PG_DSN")
  if dsn.len == 0:
    stderr.writeLine("janitor: MAJADU_PG_DSN is required")
    quit(2)
  let db = openDb(dsn, 1)
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
