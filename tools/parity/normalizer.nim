import std/[algorithm, json, re]

let
  reUuid = re"""[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"""
  # RFC 3339 and PostgreSQL's text rendering (`2026-11-04 14:06:13.35+07`).
  reTimestamp = re"""\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}(?::?\d{2})?)?"""
  reShareCode = re"""/s/[A-Za-z0-9_-]+"""
  # The authorize origin comes from deployment config; the query does not.
  reAuthorize = re"""(?:https?://[^/?\s"]+/authorize)\?"""
  # OIDC flow secrets: `state`, `nonce` and the PKCE challenge are per request.
  reState = re"""\bstate=[^&\s"]+"""
  reNonce = re"""\bnonce=[^&\s"]+"""
  reChallenge = re"""\bcode_challenge=[^&\s"]+"""
  reRedirect = re"""\bredirect_uri=[^&\s"]+"""
  # 128-bit share codes and 256-bit websocket tickets are lowercase hex.
  reTicket = re"""\b[0-9a-f]{64}\b"""
  reShare = re"""\b[0-9a-f]{32}\b"""
  reNumber = re"""\d+"""

proc normalizeText*(value: string): string =
  result = value.replace(reUuid, "{uuid}")
  result = result.replace(reTimestamp, "{timestamp}")
  result = result.replace(reShareCode, "/s/{code}")
  result = result.replace(reAuthorize, "{authorizeUrl}?")
  result = result.replace(reState, "state={random}")
  result = result.replace(reNonce, "nonce={random}")
  result = result.replace(reChallenge, "code_challenge={random}")
  result = result.replace(reRedirect, "redirect_uri={redirectUri}")
  result = result.replace(reTicket, "{ticket}")
  result = result.replace(reShare, "{shareCode}")

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
    for key in keys:
      # A board snapshot names the day it was taken; the fixtures cannot pin
      # that clock, so the value is masked while every other date stays.
      if key == "asOf":
        result[key] = %"{date}"
      else:
        result[key] = normalizeJson(node[key])
  else: result = node
