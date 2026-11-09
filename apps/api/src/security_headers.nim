import std/[json, os, strutils]
import mummy
import platform/config/store

type
  CsrfVerdict* = enum
    csrfOk
    csrfRejected

const
  stateChanging = ["POST", "PUT", "PATCH", "DELETE"]
  ## HSTS max-age for one year. Named because the header is a security promise
  ## whose duration must be readable at the call site (SQ-20).
  hstsMaxAgeSeconds = 31536000

proc allowedOrigins*(snapshot: Snapshot): seq[string] =
  ## The seeded config is the per-deployment list the operator can edit without
  ## a restart; `CORS_ALLOWED_ORIGINS` is what provisioning sets. Both are
  ## explicit allowlists, so the check stays fail-closed.
  for value in snapshot.jsonValue(%*{}, keySecurityAllowedOrigins):
    result.add(value.getStr())
  for part in getEnv("CORS_ALLOWED_ORIGINS").split(','):
    let origin = part.strip()
    if origin.len > 0 and origin notin result:
      result.add(origin)

proc originAllowed*(snapshot: Snapshot, origin: string): bool =
  if origin.len == 0:
    return true
  origin in allowedOrigins(snapshot)

proc csrfCheck*(request: Request, snapshot: Snapshot): CsrfVerdict =
  ## Browser requests must come from an allowed origin. `Sec-Fetch-Site` is
  ## checked too because a cross-site form post can omit Origin. A request that
  ## carries the session cookie is browser-driven, and browsers always send
  ## Origin on state-changing methods, so its absence is refused as well.
  ## Requests with neither header nor the session cookie are not browser
  ## sessions (CLI, health checks) and pass.
  if request.httpMethod notin stateChanging:
    return csrfOk
  let origin = request.headers["Origin"]
  if origin.len > 0:
    return if originAllowed(snapshot, origin): csrfOk else: csrfRejected
  let site = request.headers["Sec-Fetch-Site"]
  if site.len > 0 and site notin ["same-origin", "none"]:
    return csrfRejected
  if request.headers["Cookie"].contains("majadu_session="):
    return csrfRejected
  csrfOk

const returnToChars = {
  'A' .. 'Z', 'a' .. 'z', '0' .. '9', '/', '.', '_', '~', '!', '$', '&',
  '\'', '(', ')', '*', '+', ',', ';', '=', ':', '@', '%', '-'}

proc safeReturnPath*(value: string): string =
  ## Only a same-origin absolute path may become a redirect after login. The
  ## value is stored on `auth.oauth_flows` and reused as a `Location` header at
  ## the callback, so both ends call this and anything else falls back to `/`.
  if value.len == 0 or value[0] != '/':
    return "/"
  if value.contains("//") or value.contains('\\') or value.contains(".."):
    return "/"
  let lowered = value.toLowerAscii()
  if lowered.contains("%2f") or lowered.contains("%5c") or
     lowered.contains("%2e"):
    return "/"
  for character in value:
    if character notin returnToChars:
      return "/"
  value

proc securityHeaders*(secure: bool): seq[(string, string)] =
  result = @[
    ("X-Content-Type-Options", "nosniff"),
    ("X-Frame-Options", "DENY"),
    ("Referrer-Policy", "no-referrer"),
    ("Permissions-Policy", "geolocation=(), microphone=(), camera=()"),
    ("Content-Security-Policy", "default-src 'none'; frame-ancestors 'none'"),
  ]
  if secure:
    result.add(("Strict-Transport-Security",
      "max-age=" & $hstsMaxAgeSeconds & "; includeSubDomains"))

proc bodyTooLarge*(request: Request, snapshot: Snapshot): bool =
  let limit = snapshot.intValue(%*{}, keySecurityMaxBodyBytes)
  request.body.len > limit

proc socketBodyCeiling*(): int =
  ## The largest body the socket accepts, for a call site that has no snapshot.
  specFor(keySecurityMaxBodyBytes).maxValue.int

proc bodyLimits*(snapshot: Snapshot): tuple[guardBytes, socketBytes: int] =
  ## The guard is the configured value; the socket cap is the registry ceiling
  ## for that key, never the configured value. mummy drops the connection before
  ## any handler runs once a body passes `maxBodyLen`, so a socket cap equal to
  ## the limit would answer an oversized request with a closed socket instead of
  ## the documented 413. Every limit an operator may store is below the ceiling,
  ## so the guard, not the transport, decides for every legal configuration;
  ## only a body past the ceiling is dropped, and no answer is possible there.
  let configured = snapshot.intValue(%*{}, keySecurityMaxBodyBytes)
  (configured, max(configured, socketBodyCeiling()))

proc jsonTooDeep*(body: string, limit: int): bool =
  ## Counts nesting without parsing, so an over-deep body is refused before
  ## `parseJson` can recurse into it and exhaust the stack. Braces inside a
  ## string are text, not nesting, so quotes and escapes are tracked.
  var depth = 0
  var inString = false
  var escaped = false
  for character in body:
    if inString:
      if escaped:
        escaped = false
      elif character == '\\':
        escaped = true
      elif character == '"':
        inString = false
      continue
    case character
    of '"': inString = true
    of '{', '[':
      inc depth
      if depth > limit:
        return true
    of '}', ']': dec depth
    else: discard
  false

proc renderHeaders*(headers: seq[(string, string)]): string =
  ## Debug helper used by tests to assert the header set without a socket.
  var lines: seq[string] = @[]
  for (key, value) in headers:
    lines.add(key & ": " & value)
  lines.join("\n")
