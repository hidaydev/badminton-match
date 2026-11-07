import std/[json, os]
import cli
import db/db
import platform/audit_retention

const program = "audit-retention"

proc dsnArg(): string =
  ## The owner DSN is a separate variable on purpose: pointing this tool at the
  ## application DSN would either fail the privilege check or, worse, work by
  ## accident on a machine where the roles are wrong.
  result = getEnv("MAJADU_AUDIT_DSN")
  if result.len == 0 and paramCount() >= 2 and paramStr(1) == "--dsn":
    result = paramStr(2)
  if result.len == 0:
    fail(program, "MAJADU_AUDIT_DSN is required (owner role, not bm2_app)")

proc main() =
  let db = openDb(dsnArg(), 1)
  defer: db.close()
  if not auditCanBeDeleted(db):
    fail(program, "current role cannot delete account.audit; run as bm2_owner")
  let days = auditRetentionDays(db)
  let deleted = purgeAudit(db, days)
  echo $(%*{"deleted": deleted, "retentionDays": days})

when isMainModule:
  main()
