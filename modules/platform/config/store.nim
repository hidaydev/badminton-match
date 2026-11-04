import std/[json, locks, options, strutils, tables]
import db/db
import registry
import logger

export registry

type
  ConfigError* = object of CatchableError

  Snapshot* = object
    version*: int64
    values*: Table[string, JsonNode]

  ConfigCache* = ref object
    ## Holds one immutable snapshot per `platform.config_version`. A write bumps
    ## the counter in the same transaction, so the next read reloads without a
    ## restart and without a TTL.
    lock: Lock
    current: Snapshot
    loaded: bool

proc validateValue(spec: KeySpec, value: JsonNode) =
  if value.kind == JNull:
    raise newException(ConfigError, "value is NULL for " & $spec.key)
  case spec.kind
  of ctInt:
    if value.kind != JInt:
      raise newException(ConfigError, $spec.key & " must be an integer")
    if spec.hasBounds and
       (value.getInt().float < spec.minValue or value.getInt().float > spec.maxValue):
      raise newException(ConfigError, $spec.key & " is outside " & $spec.minValue &
        ".." & $spec.maxValue)
  of ctDecimal:
    if value.kind notin {JInt, JFloat}:
      raise newException(ConfigError, $spec.key & " must be a decimal")
    if spec.hasBounds and
       (value.getFloat() < spec.minValue or value.getFloat() > spec.maxValue):
      raise newException(ConfigError, $spec.key & " is outside " & $spec.minValue &
        ".." & $spec.maxValue)
  of ctBool:
    if value.kind != JBool:
      raise newException(ConfigError, $spec.key & " must be a boolean")
  of ctString:
    if value.kind != JString or value.getStr().len == 0:
      raise newException(ConfigError, $spec.key & " must be a non-empty string")
  of ctJson:
    discard

proc loadSnapshot*(db: Db): Snapshot =
  ## Reads every registry key. Missing keys, wrong types or values outside the
  ## frozen bounds refuse to start: there is no hidden default in code.
  result.values = initTable[string, JsonNode]()
  let versionRow = db.queryOne(
    "select version from platform.config_version").get
  result.version = parseInt(versionRow.get("version"))
  for row in db.query("select key, value from platform.config"):
    result.values[row.get("key")] = parseJson(row.get("value"))
  var problems: seq[string] = @[]
  for entry in allKeys:
    let key = $entry.key
    if not result.values.hasKey(key):
      problems.add("missing key: " & key)
      continue
    try:
      validateValue(entry, result.values[key])
    except ConfigError as error:
      problems.add(error.msg)
  if problems.len > 0:
    raise newException(ConfigError, "invalid platform config: " & problems.join("; "))

proc newConfigCache*(db: Db): ConfigCache =
  result = ConfigCache()
  initLock(result.lock)
  result.current = loadSnapshot(db)
  result.loaded = true

proc snapshot*(cache: ConfigCache, db: Db): Snapshot =
  acquire(cache.lock)
  try:
    let versionRow = db.queryOne("select version from platform.config_version").get
    let version = parseInt(versionRow.get("version"))
    if not cache.loaded or version != cache.current.version:
      cache.current = loadSnapshot(db)
      cache.loaded = true
      logInfo("config reloaded", [("version", $cache.current.version)])
    result = cache.current
  finally:
    release(cache.lock)

proc lookup(snapshot: Snapshot, key: ConfigKey): JsonNode =
  let name = $key
  if not snapshot.values.hasKey(name):
    raise newException(ConfigError, "configuration key is not loaded: " & name)
  snapshot.values[name]

proc communityValue*(settings: JsonNode, key: ConfigKey): Option[JsonNode] =
  ## L2 lookup. Community overrides live in `community.settings.values`.
  if settings.kind != JObject or not settings.hasKey($key):
    return none(JsonNode)
  some(settings[$key])

proc intValue*(snapshot: Snapshot, settings: JsonNode, key: ConfigKey): int =
  ## L2 -> L1 -> error. Community values are validated against the L1 ceiling.
  let override = communityValue(settings, key)
  if override.isSome:
    let spec = specFor(key)
    validateValue(spec, override.get)
    if spec.hasBounds and override.get.getInt().float > spec.maxValue:
      raise newException(ConfigError, $key & " exceeds the platform ceiling")
    return override.get.getInt()
  lookup(snapshot, key).getInt()

proc decimalValue*(snapshot: Snapshot, settings: JsonNode, key: ConfigKey): float =
  let override = communityValue(settings, key)
  if override.isSome:
    validateValue(specFor(key), override.get)
    return override.get.getFloat()
  lookup(snapshot, key).getFloat()

proc stringValue*(snapshot: Snapshot, settings: JsonNode, key: ConfigKey): string =
  let override = communityValue(settings, key)
  if override.isSome:
    validateValue(specFor(key), override.get)
    return override.get.getStr()
  lookup(snapshot, key).getStr()

proc boolValue*(snapshot: Snapshot, settings: JsonNode, key: ConfigKey): bool =
  let override = communityValue(settings, key)
  if override.isSome:
    validateValue(specFor(key), override.get)
    return override.get.getBool()
  lookup(snapshot, key).getBool()

proc jsonValue*(snapshot: Snapshot, settings: JsonNode, key: ConfigKey): JsonNode =
  let override = communityValue(settings, key)
  if override.isSome:
    return override.get
  lookup(snapshot, key)
