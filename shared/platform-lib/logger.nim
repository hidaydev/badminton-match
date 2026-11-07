import std/[json, re, times]
import clock

let
  reCodePath = re"""/s/[A-Za-z0-9_-]+"""
  # Anchored at a query separator so a parameter whose name merely ends in
  # "code" (zipcode, encode) keeps its value.
  reQuerySecret = re"""(?i)(?<![A-Za-z0-9_])((?:code|token|key|ticket)=)[^&\s"]+"""
  reSecretHeader = re"""(?i)(authorization|cookie)(:\s*)[^"\n]+"""
  reEmail = re"""[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"""
  reIpv4 = re"""\b\d{1,3}(?:\.\d{1,3}){3}\b"""
  # Compressed (any "::") and full eight-group forms only: a clock reading such
  # as 12:00:00 and a hex hash must never match.
  reIpv6 = re"""(?i)(?<![0-9a-z:.])(?:(?:[0-9a-f]{0,4}:){1,7}:(?:[0-9a-f]{1,4}(?::[0-9a-f]{1,4}){0,6})?|(?:[0-9a-f]{1,4}:){7}[0-9a-f]{1,4})(?![0-9a-z:.])"""

proc redact*(text: string): string =
  ## Removes values that must never reach logs: share codes in paths and query
  ## strings, ws tickets, auth/cookie header values, emails and IP addresses.
  result = text
  result = result.replace(reCodePath, "/s/{code}")
  result = result.replacef(reQuerySecret, "$1REDACTED")
  result = result.replacef(reSecretHeader, "$1$2REDACTED")
  result = result.replace(reEmail, "{email}")
  # IPv4 first: a mapped ::ffff:1.2.3.4 must not be split across two rules.
  result = result.replace(reIpv4, "{ip}")
  result = result.replace(reIpv6, "{ip}")

proc utcNowIso*(): string =
  ## Log timestamps are UTC; MAJADU_NOW is honoured through clock.utcNow.
  clock.utcNow().format("yyyy-MM-dd'T'HH:mm:ss'Z'")

proc renderLog*(level, msg: string, fields: openArray[(string, string)],
    values: openArray[(string, JsonNode)] = []): string =
  ## One JSON object per line. String fields are redacted before
  ## serialisation. `values` keeps a field's JSON type (a number, a nested
  ## object) instead of turning it into a string.
  var node = %*{
    "ts": $utcNowIso(),
    "level": level,
    "msg": msg,
  }
  for (key, value) in fields:
    node[key] = %redact(value)
  for (key, value) in values:
    node[key] = value
  $node


proc emit(level, msg: string, fields: openArray[(string, string)],
    values: openArray[(string, JsonNode)] = []) =
  stdout.writeLine renderLog(level, msg, fields, values)

proc logInfo*(msg: string, fields: openArray[(string, string)] = [],
    values: openArray[(string, JsonNode)] = []) =
  emit("info", msg, fields, values)

proc logWarn*(msg: string, fields: openArray[(string, string)] = []) =
  emit("warn", msg, fields)

proc logError*(msg: string, fields: openArray[(string, string)] = []) =
  emit("error", msg, fields)
