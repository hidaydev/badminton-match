import std/[json, options]
import db/db
import account/domain/audit
import account/infrastructure/audit_store
import platform/config/store

type
  SettingsOutcome* = enum
    soOk
    soUnknownKey
    soOutOfCeiling
    soInvalidType

  SettingsResult* = object
    outcome*: SettingsOutcome
    key*: string
    detail*: string

proc knownKey(name: string): Option[ConfigKey] =
  for entry in allKeys:
    if $entry.key == name:
      return some(entry.key)
  none(ConfigKey)

proc specOf(key: ConfigKey): KeySpec =
  for entry in allKeys:
    if entry.key == key:
      return entry
  raise newException(ValueError, "key is not registered")

proc validate(snapshot: Snapshot, key: ConfigKey, value: JsonNode): SettingsResult =
  ## Community overrides may only narrow a platform value: the L1 value is the
  ## ceiling and a type mismatch is rejected before anything is written.
  let spec = specOf(key)
  let platform = snapshot.jsonValue(%*{}, key)
  if value.kind != platform.kind:
    return SettingsResult(outcome: soInvalidType, key: $key,
      detail: "expected " & $platform.kind & ", got " & $value.kind)
  if spec.hasBounds and value.kind in {JInt, JFloat}:
    if value.getFloat() > platform.getFloat():
      return SettingsResult(outcome: soOutOfCeiling, key: $key,
        detail: "override exceeds the platform value")
    if value.getFloat() < spec.minValue:
      return SettingsResult(outcome: soOutOfCeiling, key: $key,
        detail: "override is below the registry minimum")
  SettingsResult(outcome: soOk, key: $key)

proc checkPatch*(snapshot: Snapshot, patch: JsonNode): SettingsResult =
  if patch.kind != JObject:
    return SettingsResult(outcome: soInvalidType, detail: "patch must be an object")
  for name, value in patch:
    let key = knownKey(name)
    if key.isNone:
      return SettingsResult(outcome: soUnknownKey, key: name,
        detail: "unknown configuration key")
    let verdict = validate(snapshot, key.get, value)
    if verdict.outcome != soOk:
      return verdict
  SettingsResult(outcome: soOk)

proc currentSettings*(db: Db, communityId: string): JsonNode =
  let row = db.queryOne(
    """select values::text as values from community.settings
       where community_id = $1::uuid""",
    @[textParam(communityId)])
  if row.isNone:
    newJObject()
  else:
    parseJson(row.get.get("values"))

proc applyPatch*(db: Db, snapshot: Snapshot, communityId, actorId: string,
                 patch: JsonNode): SettingsResult =
  ## Merge, validate, write and audit in that order. The audit row keeps the
  ## old and new values, sanitised by the domain allowlist.
  result = checkPatch(snapshot, patch)
  if result.outcome != soOk:
    return
  let before = currentSettings(db, communityId)
  var merged = before
  for name, value in patch:
    merged[name] = value
  discard db.execUpdate(
    """insert into community.settings (community_id, values, updated_at)
       values ($1::uuid, $2::jsonb, now())
       on conflict (community_id) do update
         set values = excluded.values, updated_at = now()""",
    @[textParam(communityId), textParam($merged)])
  var evidence = newJObject()
  for name in patch.keys:
    evidence[name] = patch[name]
  recordAudit(db, auditEvent("config.override", communityId, actorId = actorId,
    actorRole = "admin", targetKind = "community", targetId = communityId,
    requestId = "-").withEvidence(before, evidence))

proc effectiveConfig*(snapshot: Snapshot, settings: JsonNode): JsonNode =
  ## Every registered key with the value that will actually be used.
  result = newJObject()
  for entry in allKeys:
    if settings.kind == JObject and settings.hasKey($entry.key):
      result[$entry.key] = %*{"value": settings[$entry.key], "source": "community"}
    else:
      result[$entry.key] = %*{"value": snapshot.jsonValue(%*{}, entry.key),
                              "source": "platform"}
