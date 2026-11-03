import std/[json, re, times]
import clock

let
  reCodePath = re"""/s/[A-Za-z0-9_-]+"""
  reTicket = re"""(ticket=)[^&\s"]+"""
  reSecretHeader = re"""(?i)(authorization|cookie)(:\s*)[^"\n]+"""
  reEmail = re"""[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"""
  reIpv4 = re"""\b\d{1,3}(?:\.\d{1,3}){3}\b"""

proc redact*(text: string): string =
  ## Removes values that must never reach logs: share codes in paths, ws
  ## tickets, auth/cookie header values, emails and IPv4 addresses.
  result = text
  result = result.replace(reCodePath, "/s/{code}")
  result = result.replacef(reTicket, "$1REDACTED")
  result = result.replacef(reSecretHeader, "$1$2REDACTED")
  result = result.replace(reEmail, "{email}")
  result = result.replace(reIpv4, "{ip}")

proc utcNowIso*(): string =
  ## Log timestamps are UTC; MAJADU_NOW is honoured through clock.utcNow.
  clock.utcNow().format("yyyy-MM-dd'T'HH:mm:ss'Z'")

proc renderLog*(level, msg: string, fields: openArray[(string, string)]): string =
  ## One JSON object per line. Values are redacted before serialisation.
  var node = %*{
    "ts": $utcNowIso(),
    "level": level,
    "msg": msg,
  }
  for (key, value) in fields:
    node[key] = %redact(value)
  $node


proc emit(level, msg: string, fields: openArray[(string, string)]) =
  stdout.writeLine renderLog(level, msg, fields)

proc logInfo*(msg: string, fields: openArray[(string, string)] = []) =
  emit("info", msg, fields)

proc logWarn*(msg: string, fields: openArray[(string, string)] = []) =
  emit("warn", msg, fields)

proc logError*(msg: string, fields: openArray[(string, string)] = []) =
  emit("error", msg, fields)
