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
  ## Reads every registry key. Missing keys, wrong types, a scope that disagrees
  ## with the registry or values outside the frozen bounds refuse to start: there
  ## is no hidden default in code.
  result.values = initTable[string, JsonNode]()
  let versionRow = db.queryOne(
    "select version from platform.config_version").get
  result.version = parseInt(versionRow.get("version"))
  var scopes = initTable[string, string]()
  for row in db.query("select key, value, scope from platform.config"):
    result.values[row.get("key")] = parseJson(row.get("value"))
    scopes[row.get("key")] = row.get("scope")
  var problems: seq[string] = @[]
  for entry in allKeys:
    let key = $entry.key
    if not result.values.hasKey(key):
      problems.add("missing key: " & key)
      continue
    # The scope decides which layer owns the value. A row that disagrees with
    # the registry is as broken as a wrong type, so it is a load problem.
    if scopes.getOrDefault(key) != $entry.scope:
      problems.add("scope mismatch for " & key & ": expected " &
        $entry.scope & ", got " & scopes.getOrDefault(key, "missing"))
    try:
      validateValue(entry, result.values[key])
    except ConfigError as error:
      problems.add(error.msg)
  if problems.len > 0:
    raise newException(ConfigError, "invalid platform config: " & problems.join("; "))

proc currentVersion(db: Db): int64 =
  ## The counter alone. It is one cheap read, and it must happen outside the
  ## cache lock: holding the lock across a database call is what would deadlock
  ## if config were ever read from inside a `db.tx`.
  parseInt(db.queryOne("select version from platform.config_version").get.get("version"))

proc newConfigCache*(db: Db): ConfigCache =
  result = ConfigCache()
  initLock(result.lock)
  result.current = loadSnapshot(db)
  result.loaded = true

proc snapshot*(cache: ConfigCache, db: Db): Snapshot =
  ## A snapshot for a version is immutable, so both the version probe and the
  ## full load run outside the lock. Two readers may reload the same version
  ## concurrently; the newest version wins and an older load never replaces a
  ## newer one.
  let version = currentVersion(db)
  acquire(cache.lock)
  let current = cache.current
  let loaded = cache.loaded
  release(cache.lock)
  if loaded and current.version == version:
    return current
  let fresh = loadSnapshot(db)
  acquire(cache.lock)
  try:
    if not cache.loaded or fresh.version >= cache.current.version:
      cache.current = fresh
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
  ## The effective value. A boolean override may only narrow the platform
  ## value, so the read is an AND: a stored `true` stops counting the moment an
  ## operator turns the platform switch off. The directory may widen instead.
  let platform = lookup(snapshot, key).getBool()
  let override = communityValue(settings, key)
  if override.isSome:
    validateValue(specFor(key), override.get)
    if mayWiden(key):
      return override.get.getBool()
    return platform and override.get.getBool()
  platform

proc jsonValue*(snapshot: Snapshot, settings: JsonNode, key: ConfigKey): JsonNode =
  let override = communityValue(settings, key)
  if override.isSome:
    return override.get
  lookup(snapshot, key)
