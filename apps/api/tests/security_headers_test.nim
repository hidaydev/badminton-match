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

  test "nesting beyond the limit is detected before parsing":
    check not jsonTooDeep("""{"a":1}""", 1)
    check not jsonTooDeep("{}", 1)
    check jsonTooDeep("{}", 0)
    check jsonTooDeep("""{"a":{"b":{}}}""", 2)
    check not jsonTooDeep("""{"a":{"b":{}}}""", 3)
    check jsonTooDeep("[[[[]]]]", 3)
    check not jsonTooDeep("[[[[]]]]", 4)

  test "braces inside a string are text, not nesting":
    check not jsonTooDeep("""{"a":"[[[["}""", 1)
    check not jsonTooDeep(r"""{"a":"\"[[["}""", 1)
    # An unclosed quote swallows the rest: the body fails parsing anyway.
    check not jsonTooDeep("""{"a":"[[[[}""", 1)
