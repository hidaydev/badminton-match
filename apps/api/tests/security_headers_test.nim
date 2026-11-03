import std/[strutils, unittest]
import ../src/security_headers

suite "security headers":
  test "HSTS is only sent for secure deployments":
    var names: seq[string] = @[]
    for (key, _) in securityHeaders(secure = false):
      names.add(key)
    check "Strict-Transport-Security" notin names
    check "Content-Security-Policy" in names

  test "every response carries nosniff and a frame policy":
    let rendered = renderHeaders(securityHeaders(secure = true))
    check rendered.contains("X-Content-Type-Options: nosniff")
    check rendered.contains("X-Frame-Options: DENY")
    check rendered.contains("Strict-Transport-Security")
