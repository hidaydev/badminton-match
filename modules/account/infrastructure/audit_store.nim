import std/json
import db/db
import logger
import ../domain/audit

const recordAuditSql = """insert into account.audit
       (actor_id, actor_role, community_id, action, target_kind, target_id,
        result, reason, request_id, before, after)
     values ($1::uuid, $2, $3::uuid, $4, $5, $6, $7, $8, $9,
             $10::jsonb, $11::jsonb)"""

proc warnDroppedEvidence(event: AuditEvent) =
  ## A key outside the allowlist never reaches the row. Saying so is the
  ## difference between "the evidence is empty" and "the caller asked for a
  ## field that the allowlist refuses"; the value itself is never logged.
  for source in [event.before, event.after]:
    for key in droppedEvidenceKeys(source):
      logWarn("audit evidence dropped",
        [("action", event.action), ("key", key)])

proc auditParams(event: AuditEvent): seq[DbParam] =
  warnDroppedEvidence(event)
  @[
    textOrNull(event.actorId),
    textParam(if event.actorRole.len == 0: "member" else: event.actorRole),
    textOrNull(event.communityId),
    textParam(event.action),
    textParam(event.targetKind),
    textParam(event.targetId),
    textParam($event.result),
    textOrNull(event.reason),
    textParam(if event.requestId.len == 0: "-" else: event.requestId),
    textParam($sanitizeEvidence(event.before)),
    textParam($sanitizeEvidence(event.after)),
  ]

proc recordAuditConn*(conn: DbConn, event: AuditEvent) =
  ## Appends one audit row on a connection the caller already holds, so the
  ## evidence commits with the write it describes instead of after it. The table
  ## grants only SELECT and INSERT to the application role, so evidence can
  ## never be rewritten.
  discard conn.execUpdate(recordAuditSql, auditParams(event))

proc recordAudit*(db: Db, event: AuditEvent) =
  ## Appends one audit row on its own connection, for a caller that holds none.
  discard db.execUpdate(recordAuditSql, auditParams(event))

proc sanitized*(node: JsonNode): JsonNode =
  sanitizeEvidence(node)
