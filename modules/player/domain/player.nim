import std/[json, options, strutils]

type
  Tier* = enum
    tD = "D"
    tDPlus = "D+"
    tC = "C"
    tCPlus = "C+"
    tB = "B"
    tBPlus = "B+"
    tA = "A"
    tAPlus = "A+"

  Gender* = enum
    gMale = "M"
    gFemale = "F"

  PlayerProblem* = enum
    ppName = "invalid_name"
    ppGender = "invalid_gender"
    ppTier = "invalid_tier"

  AliasProblem* = enum
    apBlank = "blank_alias"
    apTooLong = "alias_too_long"
    apDuplicate = "duplicate_alias"

  PlayerPatch* = object
    ## Only fields the caller actually sent are changed. `clearTier` exists
    ## because JSON null and "absent" cannot be told apart by `Option` alone.
    name*: Option[string]
    gender*: Option[Gender]
    tier*: Option[Tier]
    clearTier*: bool
    aliases*: Option[seq[string]]

const maxNameLength = 80

proc normalizeName*(raw: string): string =
  ## Collapsing whitespace here means the generated canonical_key never sees two
  ## spellings of the same name from our own writes.
  let stripped = raw.strip()
  var parts: seq[string] = @[]
  for part in stripped.splitWhitespace():
    parts.add(part)
  parts.join(" ")

proc parseTier*(value: string): Tier =
  case value
  of "D": tD
  of "D+": tDPlus
  of "C": tC
  of "C+": tCPlus
  of "B": tB
  of "B+": tBPlus
  of "A": tA
  of "A+": tAPlus
  else: raise newException(ValueError, "unknown tier: " & value)

proc parseGender*(value: string): Gender =
  case value.toUpperAscii()
  of "M": gMale
  of "F": gFemale
  else: raise newException(ValueError, "unknown gender: " & value)

proc checkCreate*(name, gender, tier: string): seq[PlayerProblem] =
  let normalized = normalizeName(name)
  if normalized.len == 0 or normalized.len > maxNameLength:
    result.add(ppName)
  try:
    discard parseGender(gender)
  except ValueError:
    result.add(ppGender)
  if tier.len > 0:
    try:
      discard parseTier(tier)
    except ValueError:
      result.add(ppTier)

proc aliasesValid*(aliases: seq[string]): bool =
  for alias in aliases:
    let normalized = normalizeName(alias)
    if normalized.len == 0 or normalized.len > maxNameLength:
      return false
  var seen: seq[string] = @[]
  for alias in aliases:
    let key = normalizeName(alias).toLowerAscii()
    if key in seen:
      return false
    seen.add(key)
  true

proc parseAliases*(node: JsonNode): seq[string] =
  if node.kind != JArray:
    raise newException(ValueError, "aliases must be an array")
  for entry in node:
    if entry.kind != JString:
      raise newException(ValueError, "aliases must be strings")
    result.add(normalizeName(entry.getStr()))

proc stringField(body: JsonNode, key: string): string =
  ## `getStr` answers its default for a non-string in Nim 2.4, so the kind has
  ## to be checked: `name: 123` used to blank the stored name.
  if body[key].kind != JString:
    raise newException(ValueError, key & " must be a string")
  body[key].getStr()

proc parsePatch*(body: JsonNode): PlayerPatch =
  ## `tier: null` clears it; an absent key leaves it untouched. That is the
  ## sticky behaviour: an update never drops a tier by accident.
  if body.kind != JObject:
    raise newException(ValueError, "patch body must be an object")
  if body.hasKey("name"):
    let name = normalizeName(stringField(body, "name"))
    if name.len == 0 or name.len > maxNameLength:
      raise newException(ValueError,
        "name must be between 1 and " & $maxNameLength & " characters")
    result.name = some(name)
  if body.hasKey("gender"):
    result.gender = some(parseGender(stringField(body, "gender")))
  if body.hasKey("tier"):
    if body["tier"].kind == JNull:
      result.clearTier = true
    else:
      result.tier = some(parseTier(stringField(body, "tier")))
  if body.hasKey("aliases"):
    result.aliases = some(parseAliases(body["aliases"]))
