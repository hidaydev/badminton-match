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

  test "another loopback address is not the proxy":
    ## SEC-14: the configured entry is the whole rule. A second local process
    ## reaching 127.0.0.1:8080 from 127.0.0.2 must not choose the address the
    ## anonymous buckets are keyed by.
    let request = fakeRequest("127.0.0.2", @[("X-Client-IP", "9.9.9.9")])
    check not peerProxied(request, @["127.0.0.1"])
    check clientIp(request, @["127.0.0.1"]) == "127.0.0.2"
    check forwardedIp(request, @["127.0.0.1"]) == ""

  test "the IPv6 loopback is honoured only when it is configured":
    let request = fakeRequest("::1", @[("X-Client-IP", "9.9.9.9")])
    check clientIp(request, @["127.0.0.1"]) == "::1"
    check clientIp(request, @["127.0.0.1", "::1"]) == "9.9.9.9"

