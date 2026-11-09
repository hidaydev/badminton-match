import std/[unittest]
import tests/fake_request
import ../src/config

suite "client address":
  test "X-Client-IP is honoured from a trusted proxy":
    let request = fakeRequest("127.0.0.1", @[("X-Client-IP", "9.9.9.9")])
    check clientIp(request, @["127.0.0.1"]) == "9.9.9.9"

  test "X-Client-IP is ignored from an untrusted peer":
    let request = fakeRequest("203.0.113.5", @[("X-Client-IP", "9.9.9.9")])
    check clientIp(request, @["127.0.0.1"]) == "203.0.113.5"

  test "the identity source is the header only from a trusted proxy":
    let trustedPeer = fakeRequest("127.0.0.1", @[("X-Client-IP", "9.9.9.9")])
    check forwardedIp(trustedPeer, @["127.0.0.1"]) == "9.9.9.9"
    let untrustedPeer = fakeRequest("203.0.113.5", @[("X-Client-IP", "9.9.9.9")])
    check forwardedIp(untrustedPeer, @["127.0.0.1"]) == ""

  test "X-Forwarded-For never changes the address":
    let request = fakeRequest("203.0.113.5",
      @[("X-Forwarded-For", "9.9.9.9"), ("X-Client-IP", "8.8.8.8")])
    check clientIp(request, @["127.0.0.1"]) == "203.0.113.5"
