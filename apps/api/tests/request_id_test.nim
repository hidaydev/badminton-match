import std/[strutils, unittest]
import ../src/server
import logger
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

  test "a crash line and its access line carry the same id":
    ## `internalFailure` and `recordResponse` both read the thread's id, which
    ## is what lets one grep find the 500 body, its access line and the audit
    ## rows of the write before it.
    beginRequest()
    let requestId = currentRequestId()
    let errorLine = renderLog("error", "request failed",
      [("error", "boom"), ("request_id", currentRequestId())])
    let accessLine = recordResponse("GET", "/c/acme/sessions/x", 500,
      "/c/{slug}/sessions", currentRequestId())
    check errorLine.contains("\"request_id\":\"" & requestId & "\"")
    check accessLine.contains("\"request_id\":\"" & requestId & "\"")

  test "the next request cannot reuse the previous id":
    beginRequest()
    let previous = currentRequestId()
    beginRequest()
    check currentRequestId() != previous