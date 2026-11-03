import std/[json, strutils]
import mummy
import platform/config/store

type
  CsrfVerdict* = enum
    csrfOk
    csrfRejected

const
  stateChanging = ["POST", "PUT", "PATCH", "DELETE"]

proc allowedOrigins*(snapshot: Snapshot): seq[string] =
  for value in snapshot.jsonValue(%*{}, keySecurityAllowedOrigins):
    result.add(value.getStr())

proc originAllowed*(snapshot: Snapshot, origin: string): bool =
  if origin.len == 0:
    return true
  origin in allowedOrigins(snapshot)

proc csrfCheck*(request: Request, snapshot: Snapshot): CsrfVerdict =
  ## Browser requests must come from an allowed origin. `Sec-Fetch-Site` is
  ## checked too because a cross-site form post can omit Origin. Requests that
  ## carry neither header are not browser-driven (CLI, tests) and pass, so the
  ## rule protects cookies without breaking automation.
  if request.httpMethod notin stateChanging:
    return csrfOk
  let origin = request.headers["Origin"]
  if origin.len > 0:
    return if originAllowed(snapshot, origin): csrfOk else: csrfRejected
  let site = request.headers["Sec-Fetch-Site"]
  if site.len > 0 and site notin ["same-origin", "none"]:
    return csrfRejected
  csrfOk

proc securityHeaders*(secure: bool): seq[(string, string)] =
  result = @[
    ("X-Content-Type-Options", "nosniff"),
    ("X-Frame-Options", "DENY"),
    ("Referrer-Policy", "no-referrer"),
    ("Permissions-Policy", "geolocation=(), microphone=(), camera=()"),
    ("Content-Security-Policy", "default-src 'none'; frame-ancestors 'none'"),
  ]
  if secure:
    result.add(("Strict-Transport-Security", "max-age=31536000; includeSubDomains"))

proc bodyTooLarge*(request: Request, snapshot: Snapshot): bool =
  let limit = snapshot.intValue(%*{}, keySecurityMaxBodyBytes)
  request.body.len > limit

proc renderHeaders*(headers: seq[(string, string)]): string =
  ## Debug helper used by tests to assert the header set without a socket.
  var lines: seq[string] = @[]
  for (key, value) in headers:
    lines.add(key & ": " & value)
  lines.join("\n")
