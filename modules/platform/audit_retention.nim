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

const auditMaintenanceSetting* = "majadu.audit_maintenance"
  ## The per-transaction opt-in the append-only trigger accepts. `0049` rejects
  ## every UPDATE and DELETE on account.audit unless this setting is `on` for
  ## the transaction, so the retention path is the only writer that can prune.

proc purgeAudit*(db: Db, retentionDays: int,
                 batchSize = auditPurgeBatch): int =
  ## Removes audit rows older than the configured window in bounded batches.
  ## Only the owner-run tool calls this; the API process never does. Each
  ## batch is its own transaction, which keeps the lock window short, and it
  ## sets the trigger's maintenance opt-in inside that same transaction so a
  ## failure cannot leave the flag on for a later statement.
  if batchSize < 1:
    raise newException(ValueError, "batchSize must be positive")
  var total = 0
  while true:
    var removed = 0
    db.tx(proc(conn: DbConn) =
      discard conn.execUpdate("select set_config($1, 'on', true)",
        @[textParam(auditMaintenanceSetting)])
      removed = conn.execUpdate(
        """delete from account.audit
           where ctid in (
             select ctid from account.audit
             where occurred_at < now() - make_interval(days => $1)
             limit $2)""",
        @[intParam(retentionDays.int64), intParam(batchSize.int64)]))
    total += removed
    if removed < batchSize:
      return total
