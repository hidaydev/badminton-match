import std/[json, options]
import db/db
import config/registry
import config/store

proc auditRetentionDays*(db: Db): int =
  loadSnapshot(db).intValue(%*{}, keyAuditRetentionDays)

proc auditCanBeDeleted*(db: Db): bool =
  ## The tool must run as the owner role; the application role has no DELETE
  ## grant on account.audit (D16). Checking here turns a silently empty delete
  ## into an explicit failure.
  let row = db.queryOne(
    "select has_table_privilege(current_user, 'account.audit', 'DELETE') as allowed")
  row.isSome and row.get.get("allowed") == "t"

const auditPurgeBatch* = 10000
  ## Rows per statement. A monthly purge used to be one DELETE over the whole
  ## window: one long transaction, one full WAL burst and one dead-tuple
  ## mountain for autovacuum. The loop below commits each batch, so a busy
  ## primary waits at most one bounded statement at a time.

proc purgeAudit*(db: Db, retentionDays: int,
                 batchSize = auditPurgeBatch): int =
  ## Removes audit rows older than the configured window in bounded batches.
  ## Only the owner-run tool calls this; the API process never does. Each
  ## `execUpdate` is its own transaction, which is what keeps the lock window
  ## short instead of holding the table for the whole purge.
  if batchSize < 1:
    raise newException(ValueError, "batchSize must be positive")
  var total = 0
  while true:
    let removed = db.execUpdate(
      """delete from account.audit
         where ctid in (
           select ctid from account.audit
           where occurred_at < now() - make_interval(days => $1)
           limit $2)""",
      @[intParam(retentionDays.int64), intParam(batchSize.int64)])
    total += removed
    if removed < batchSize:
      return total
