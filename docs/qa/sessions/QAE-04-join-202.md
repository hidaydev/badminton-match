# QAE-04: the join request answers 202 to everyone

Session of 2026-11-10 on `w3/qae` (based on `0e3000c1`), charter
`docs/qa/charter-http-boundary.md`. Scratch database `bm2_w3qa`, release build on
8098, no session cookie.

## Steps and results

```
curl -sS -o /tmp/j1.out -w 'status=%{http_code}\n' -X POST \
  -H 'Content-Type: application/json' \
  --data '{"name":"Audit Probe","phone":"0812"}' \
  http://127.0.0.1:8098/c/demo/join-requests
# status=202
# {"status":"accepted"}

curl -sS -o /tmp/j2.out -w 'status=%{http_code}\n' -X POST \
  -H 'Content-Type: application/json' --data '{bad' \
  http://127.0.0.1:8098/c/demo/join-requests
# status=202
# {"status":"accepted"}

curl -sS -o /tmp/j3.out -w 'status=%{http_code}\n' -X POST \
  -H 'Content-Type: application/json' --data '{"name":"x"}' \
  http://127.0.0.1:8098/c/no-such-community/join-requests
# status=202
# {"status":"accepted"}

psql -d bm2_w3qa -tAc "select count(*) from community.join_request"
# 0
```

Three callers, three different truths, one response. The malformed body is not
parsed and the unknown slug is not looked up for an anonymous caller, so the 202
is not a receipt: it is the only answer the route gives.

## Assessment

This is the anti-enumeration design recorded in
`apps/api/src/app.nim:1486-1512`: an anonymous caller must not be able to tell
an accepting community from a closed one, from an unknown slug, or from a body
that would never be stored. A 4xx for "a session is required" would answer the
question the response is hiding, so the audit's suggestion and the design
conflict, and the design wins.

The cost is the one the audit named: a client that trusts the 202 will believe a
request was recorded when nothing was. That is acceptable only while the 202 is
documented as an acknowledgement and the browser never treats it as a receipt.
The client does not today; this note is the record that it must not start.

## DoD status

"No DoD required. If the flow changes, document the 202 semantics in the API
contract." The flow has not changed, so nothing is owed to the contract. The
semantics are recorded here and pinned by the check below, so a future change
that makes the answer truthful has to change the test and this note with it.

## Permanent check

`e2e/api.spec.ts` ("QAE-04: the join request answers 202 to every anonymous
caller") posts a well-formed body, a malformed one and an unknown slug, and
asserts all three are 202 with exactly `{"status":"accepted"}` and no extra
member that would look like a receipt.
