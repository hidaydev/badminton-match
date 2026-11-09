# QAE-02: an oversized body must be answered, not dropped

Session of 2026-11-10 on `w3/qae` (based on `0e3000c1`), charter
`docs/qa/charter-http-boundary.md`. Scratch database `bm2_w3qa`, release build
from `./task build`, port 8098, no session cookie.

## Setup

```
dbtools migrate --dir db/migrations   # 48 file(s)
dbtools seed --dir db/seeds           # 2 file(s)
psql -d bm2_w3qa -c "select value from platform.config where key='security.max_body_bytes'"
# 1048576
```

```
MAJADU_PG_DSN=postgresql://$USER@127.0.0.1:5432/bm2_w3qa \
MAJADU_PORT=8098 MAJADU_DRAIN_MS=0 \
SHARE_CODE_KEYS='{"1":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="}' \
SHARE_CODE_ACTIVE_KEY_ID=1 OIDC_CLIENT_ID=majadu-qa \
OIDC_REDIRECT_URI=http://127.0.0.1:5173/api/auth/callback \
  .cache/w3-qae-4f99a6a3/bin/majadu-api > /tmp/w3qa-api.log 2>&1 &
```

## Steps and results

The audit probe was 2 MB at a 1 MiB limit.

```
curl -sS -o /tmp/r2.out -w 'status=%{http_code}\n' -X POST \
  -H 'Content-Type: application/json' --data-binary @/tmp/body2mb.bin \
  http://127.0.0.1:8098/c/demo/join-requests
# status=413
# {"type":"about:blank","title":"BODY_TOO_LARGE","status":413,
#  "code":"BODY_TOO_LARGE","i18nKey":"error.bodyTooLarge",
#  "detail":"request body exceeds the limit"}
```

The 2 MB connection reset the audit recorded is gone. The envelope is byte for
byte the shape a 404 carries, field for field:

```
curl -sS http://127.0.0.1:8098/nope
# {"type":"about:blank","title":"NOT_FOUND","status":404,
#  "code":"NOT_FOUND","i18nKey":"error.notFound","detail":"route not found"}
```

The boundary at the configured limit, one byte either side:

```
exactly 1048576 bytes  -> status=202 {"status":"accepted"}
exactly 1048577 bytes  -> status=413 BODY_TOO_LARGE
```

The transport ceiling, 16 MiB (the registry maximum for
`security.max_body_bytes`):

```
16777216 bytes    -> status=413
16777217 bytes    -> curl: (52) Empty reply from server   (status=000)
20971520 bytes    -> curl: (52) Empty reply from server   (status=000)
healthz after     -> {"status":"ok"} [200]
```

The process survives, and the socket is closed by mummy before a handler runs,
which `apps/api/src/security_headers.nim:88-98` documents as "no answer is
possible there". So the answer boundary is 16 MiB, not the configured 1 MiB, and
anything past the ceiling is still a network failure to the client.

The rejection is logged like every other answer when the guard decides:

```
{"ts":"2026-11-09T19:24:57Z","level":"info","msg":"request","method":"POST",
 "route":"/c/{slug}/join-requests","status":"413",
 "request_id":"01a1c1c5-541a-7f1d-b0ce-eedfd20da990"}
```

The response headers, however, do not carry `Connection: close`:

```
HTTP/1.1 413
Content-Type: application/problem+json
X-Content-Type-Options: nosniff
...
Content-Length: 157
```

## DoD status

1. "a body over the limit returns 413 with the standard problem envelope and
   `Connection: close`": **partly**. The envelope is right for every body the
   socket accepts (up to 16 MiB), and `BODY_TOO_LARGE` is the same envelope as
   every other rejection. `Connection: close` is absent, and a body past the
   transport ceiling is still a closed socket. Both need `apps/api/src/app.nim`
   (`rejectLargeBody`, the `problem` call) and a transport decision, so they are
   recorded here rather than changed from the QA tree.
2. "the rejection is logged as JSON with the same fields as other requests":
   **satisfied** for the guard path, see the line above.
3. "a test covers the boundary at the configured maximum": **satisfied** by
   `apps/api/tests/integration/body_limit_http_test.nim` (at the limit, one byte
   over, one byte under) and now also by `e2e/api.spec.ts`, which reads the
   limit from `db/seeds/platform_config.sql` and probes the same boundary over
   the real socket.

## Permanent check

`e2e/api.spec.ts` ("an oversized body", "the body limit is the configured
value", "the 413 envelope") sends 2 MB and the two boundary bodies straight to
the API the e2e harness started, so the audit probe is re-run on every suite run.
It asserts the 413, the envelope parity with a 404, and that the API answers
`/healthz` afterwards. It does not assert `Connection: close`, because that
header is not sent yet.
