import std/[json, strutils]

type
  AuditResult* = enum
    arAllow = "allow"
    arDeny = "deny"
    arError = "error"

  AuditEvent* = object
    ## Shape of one row in `account.audit`. The domain owns it; the SQL lives in
    ## the infrastructure adapter so this module stays free of the database.
    actorId*: string
    actorRole*: string
    communityId*: string
    action*: string
    targetKind*: string
    targetId*: string
    result*: AuditResult
    reason*: string
    requestId*: string
    before*: JsonNode
    after*: JsonNode

const
  ## Evidence is allow-listed field by field. Anything else is dropped rather
  ## than logged: audit rows must never carry a share code, an email or an IP.
  ## Lowercase on purpose: matching is case-insensitive, and the stored JSON
  ## keeps the caller's key so the evidence stays readable. `reason` is here so
  ## a rejection or an anonymisation leaves a sentence instead of an empty row;
  ## the Google `sub` is deliberately absent, because it is a stable external
  ## identifier and the audit table outlives the account. Correlation is
  ## `request_id` plus `reason`.
  evidenceAllowlist = [
    "slug", "name", "title", "date", "status", "role", "version",
    "sessionid", "playerid", "claimid", "matchid", "tournamentid",
    "fromrole", "torole", "count", "rating", "reason", "route",
  ]

  forbiddenKeys = ["code", "email", "ip", "token", "cookie", "ticket",
                   "password", "secret", "authorization"]

proc configKeyLike(key: string): bool =
  ## Registry keys are lowercase and dotted. They are allowed as evidence because
  ## a settings change is meaningless without them, while the forbidden-substring
  ## check below still blocks names such as `auth.token`.
  if '.' notin key or key.len == 0:
    return false
  for c in key:
    if c notin {'a'..'z', '0'..'9', '_', '.'}:
      return false
  true

proc evidenceKeyKept(key: string): bool =
  ## Shared by the sanitiser and the drop report so both agree on what survives.
  let lowered = key.toLowerAscii()
  if lowered notin evidenceAllowlist and not configKeyLike(lowered):
    return false
  for part in forbiddenKeys:
    if lowered.contains(part):
      return false
  true

proc sanitizeEvidence*(node: JsonNode): JsonNode =
  ## Keeps allow-listed keys with scalar values. Nested objects and arrays are
  ## dropped because they can smuggle unlisted data into the row.
  if node.kind != JObject:
    return newJObject()
  result = newJObject()
  for key, value in node:
    if not evidenceKeyKept(key):
      continue
    case value.kind
    of JString, JInt, JFloat, JBool, JNull:
      result[key] = value
    else:
      discard

proc droppedEvidenceKeys*(node: JsonNode): seq[string] =
  ## The keys `sanitizeEvidence` removes, so the adapter can say which evidence
  ## never reached the row. Only the key name is reported: the value may be the
  ## secret the allowlist exists to keep out.
  if node.kind != JObject:
    return @[]
  for key, value in node:
    if not evidenceKeyKept(key) or
        value.kind notin {JString, JInt, JFloat, JBool, JNull}:
      result.add(key)

proc forbid*(key: string): bool =
  ## True when a field name can never be persisted as audit evidence.
  let lowered = key.toLowerAscii()
  for part in forbiddenKeys:
    if lowered.contains(part):
      return true
  lowered notin evidenceAllowlist

proc auditEvent*(action: string, communityId: string,
                 actorId = "", actorRole = "member",
                 outcome = arAllow, targetKind = "", targetId = "",
                 reason = "", requestId = ""): AuditEvent =
  AuditEvent(actorId: actorId, actorRole: actorRole, communityId: communityId,
    action: action, targetKind: targetKind, targetId: targetId, result: outcome,
    reason: reason, requestId: requestId, before: newJObject(), after: newJObject())

proc withEvidence*(event: AuditEvent, before, after: JsonNode): AuditEvent =
  result = event
  result.before = sanitizeEvidence(before)
  result.after = sanitizeEvidence(after)
