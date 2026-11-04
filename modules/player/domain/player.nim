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

  PlayerPatch* = object
    ## Only fields the caller actually sent are changed. `clearTier` exists
    ## because JSON null and "absent" cannot be told apart by `Option` alone.
    name*: Option[string]
    gender*: Option[Gender]
    tier*: Option[Tier]
    clearTier*: bool

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

proc parsePatch*(body: JsonNode): PlayerPatch =
  ## `tier: null` clears it; an absent key leaves it untouched. That is the
  ## sticky behaviour: an update never drops a tier by accident.
  if body.kind != JObject:
    raise newException(ValueError, "patch body must be an object")
  if body.hasKey("name"):
    result.name = some(normalizeName(body["name"].getStr()))
  if body.hasKey("gender"):
    result.gender = some(parseGender(body["gender"].getStr()))
  if body.hasKey("tier"):
    if body["tier"].kind == JNull:
      result.clearTier = true
    else:
      result.tier = some(parseTier(body["tier"].getStr()))
