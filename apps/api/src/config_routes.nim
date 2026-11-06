import std/[json, options]
import db/db
import account/domain/audit
import account/infrastructure/audit_store
import platform/config/store

type
  SettingsOutcome* = enum
    soOk
    soUnknownKey
    soPlatformScope
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
  ## ceiling and a type mismatch is rejected before anything is written. Only
  ## registry keys scoped to the community reach this point: a platform key is
  ## read from the platform snapshot by every consumer, so storing a per-community
  ## copy would report a value nothing uses.
  let spec = specOf(key)
  if spec.scope != csCommunity:
    return SettingsResult(outcome: soPlatformScope, key: $key,
      detail: "key is managed at the platform level")
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
  # A community may narrow a number, not overrule a platform switch. The
  # directory is the documented exception: it is opt-in per community and the
  # platform value is the default, not a ceiling.
  if value.kind == JBool and value.getBool() and not platform.getBool() and
      not mayWiden(key):
    return SettingsResult(outcome: soOutOfCeiling, key: $key,
      detail: "override may not enable a platform-disabled flag")
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
                 patch: JsonNode, requestId = "-",
                 actorRole = "admin"): SettingsResult =
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
    actorRole = actorRole, targetKind = "community", targetId = communityId,
    requestId = requestId).withEvidence(before, evidence))

proc visibleSettings*(settings: JsonNode): JsonNode =
  ## What the caller is allowed to see back: an old row may hold a platform key
  ## written before the scope was enforced, and that must not resurface here.
  result = newJObject()
  if settings.kind != JObject:
    return
  for name, value in settings:
    let key = knownKey(name)
    if key.isSome and specOf(key.get).scope == csCommunity:
      result[name] = value

proc effectiveConfig*(snapshot: Snapshot, settings: JsonNode): JsonNode =
  ## The community-scoped keys with the value that will actually be used.
  ## Platform keys are left out on purpose: every member may read this, and the
  ## security and session settings are not theirs to inspect.
  result = newJObject()
  for entry in allKeys:
    if entry.scope != csCommunity:
      continue
    if settings.kind == JObject and settings.hasKey($entry.key):
      let value =
        if entry.kind == ctBool:
          %snapshot.boolValue(settings, entry.key)
        else:
          settings[$entry.key]
      result[$entry.key] = %*{"value": value, "source": "community"}
    else:
      result[$entry.key] = %*{"value": snapshot.jsonValue(%*{}, entry.key),
                              "source": "platform"}
