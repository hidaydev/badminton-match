import std/[algorithm, json, re, strutils]

let
  reUuid = re"""[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"""
  reTimestamp = re"""\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z"""
  reShareCode = re"""/s/[A-Za-z0-9_-]+"""
  reNumber = re"""\d+"""

proc normalizeText*(value: string): string =
  result = value.replace(reUuid, "{uuid}")
  result = result.replace(reTimestamp, "{timestamp}")
  result = result.replace(reShareCode, "/s/{code}")

proc normalizePlainText*(value: string): string =
  ## Non-JSON payloads (for example /metrics) carry counters and durations that
  ## change between runs, so mask every number as well.
  normalizeText(value).replace(reNumber, "{number}")

proc normalizeJson*(node: JsonNode): JsonNode =
  case node.kind
  of JString: result = %normalizeText(node.getStr())
  of JArray:
    result = newJArray()
    for item in node: result.add(normalizeJson(item))
  of JObject:
    result = newJObject()
    var keys: seq[string] = @[]
    for key in node.keys: keys.add(key)
    keys.sort()
    for key in keys: result[key] = normalizeJson(node[key])
  else: result = node
