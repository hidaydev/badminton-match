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

proc purgeAudit*(db: Db, retentionDays: int): int =
  ## Removes audit rows older than the configured window. Only the owner-run
  ## tool calls this; the API process never does.
  db.execUpdate(
    """delete from account.audit
       where occurred_at < now() - make_interval(days => $1)""",
    @[intParam(retentionDays.int64)])
