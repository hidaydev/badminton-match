import std/[strutils, unittest]
import ../src/server
import account/domain/audit

# `route()` starts the id, `recordResponse` prints it and the audit wrappers in
# app.nim read it back for every row they write. This suite pins the shared
# source of truth: two rows and the access-log line of one request must carry
# one id, so a 500 can be paired with the write that preceded it.
suite "request correlation":
  test "every audit row of one request shares the access-log id":
    beginRequest()
    let requestId = currentRequestId()
    check requestId.len == 36
    let first = auditEvent("community.create", "c1",
      requestId = currentRequestId())
    let second = auditEvent("community.member.add", "c1",
      requestId = currentRequestId())
    let line = recordResponse("POST", "/communities", 500, "/communities",
      currentRequestId())
    check line.contains("\"request_id\":\"" & requestId & "\"")
    check first.requestId == requestId
    check second.requestId == requestId

  test "the next request cannot reuse the previous id":
    beginRequest()
    let previous = currentRequestId()
    beginRequest()
    check currentRequestId() != previous