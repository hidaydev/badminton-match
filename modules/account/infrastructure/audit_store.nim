import std/json
import db/db
import ../domain/audit

proc optionalParam(value: string): DbParam =
  if value.len == 0: nullParam() else: textParam(value)

proc recordAudit*(db: Db, event: AuditEvent) =
  ## Appends one audit row. The table grants only SELECT and INSERT to the
  ## application role, so evidence can never be rewritten.
  discard db.execUpdate(
    """insert into account.audit
         (actor_id, actor_role, community_id, action, target_kind, target_id,
          result, reason, request_id, before, after)
       values ($1::uuid, $2, $3::uuid, $4, $5, $6, $7, $8, $9,
               $10::jsonb, $11::jsonb)""",
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
    ])

proc sanitized*(node: JsonNode): JsonNode =
  sanitizeEvidence(node)
