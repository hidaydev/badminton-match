import std/json
import cli
import db/db
import platform/config/store
import platform/janitor

const
  program = "janitor"
  # The janitor deletes in bounded batches (`janitorPurgeBatch`), so the bound
  # belongs to one statement, not to the whole backlog: the same value the API
  # uses is enough, and a batch that cannot finish inside it leaves the rest for
  # the next run, because the predicate is time-based. Zero (the pool default)
  # would let one delete hold the nightly run open with no upper bound.
  statementTimeoutMs = defaultStatementTimeoutMs

proc main() =
  let db = openDb(dsnOrFail(program), 1,
    statementTimeoutMs = statementTimeoutMs)
  defer: db.close()
  let days = loadSnapshot(db).intValue(%*{}, keyJanitorRetentionDays)
  var rows = newJArray()
  var total = 0
  var communities = 0
  for outcome in purgeCounting(db, days, communities):
    rows.add(%*{"table": outcome.table, "deleted": outcome.deleted})
    total += outcome.deleted
  # A sweep that inspected no community deleted nothing anywhere, and its report
  # is byte-identical to a night with nothing to purge. Fail on a non-zero exit
  # with a line on stderr; the JSON payload on a real run stays as it was.
  if communities == 0:
    fail(program, "no communities to purge")
  echo $(%*{"retentionDays": days, "deleted": total, "tables": rows})

when isMainModule:
  main()
