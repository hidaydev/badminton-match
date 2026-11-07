import std/json
import db/db
import ../domain/audit

proc optionalParam(value: string): DbParam =
  if value.len == 0: nullParam() else: textParam(value)

const recordAuditSql = """insert into account.audit
       (actor_id, actor_role, community_id, action, target_kind, target_id,
        result, reason, request_id, before, after)
     values ($1::uuid, $2, $3::uuid, $4, $5, $6, $7, $8, $9,
             $10::jsonb, $11::jsonb)"""

proc auditParams(event: AuditEvent): seq[DbParam] =
  @[
    optionalParam(event.actorId),
    textParam(if event.actorRole.len == 0: "member" else: event.actorRole),
    optionalParam(event.communityId),
    textParam(event.action),
    textParam(event.targetKind),
    textParam(event.targetId),
    textParam($event.result),
    optionalParam(event.reason),
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
