# QAE-03: a flag that answers health checks and serves nothing

Session of 2026-11-10 on `w3/qae` (based on `0e3000c1`), charter
`docs/qa/charter-http-boundary.md`. Scratch database `bm2_w3qa`, no session
cookie.

Two binaries from the same tree: the release build from `./task build`, and a
debug build (`nim c` without `-d:release`), because the flag is compiled out of
a release build and its refusal path only exists in a debug one.

## The stub in a debug build

```
MAJADU_PG_DSN=postgresql://$USER@127.0.0.1:5432/bm2_w3qa \
MAJADU_PORT=8095 MAJADU_DRAIN_MS=0 MAJADU_TEST_ROUTES=1 \
  .cache/w3-qae-4f99a6a3/bin/majadu-api-debug > /tmp/w3qa-stub.log 2>&1 &
```

```
/healthz        -> {"status":"stub"} [200]
/readyz         -> 404
/version        -> 404
/c/x/sessions   -> 404
```

So `/healthz` answers 200 for a process that serves no route. `/readyz` is a
404 from the stub's fall-through, not from the real handler: a readiness probe
treats it as a failure, which is the one thing that keeps this from being an
outage, but the status the DoD asked for is 503.

The production signal is refused outright:

```
MAJADU_ENV=prod MAJADU_PORT=8095 MAJADU_DRAIN_MS=0 MAJADU_TEST_ROUTES=1 \
  .cache/w3-qae-4f99a6a3/bin/majadu-api-debug
# majadu-api: MAJADU_TEST_ROUTES=1 refuses a release configuration
```

## The same flag in a release build

```
MAJADU_PORT=8097 MAJADU_DRAIN_MS=0 MAJADU_TEST_ROUTES=1 \
  .cache/w3-qae-4f99a6a3/bin/majadu-api            # release build
# {"ts":"...","level":"info","msg":"startup flags","testRoutes":"false",...}
```

The first attempt had no `OIDC_CLIENT_ID`, and the process said so:

```
majadu-api: OIDC_CLIENT_ID and OIDC_REDIRECT_URI are required
```

which is the proof that it booted the real application instead of the stub.
With the OIDC variables set:

```
/healthz        -> {"status":"ok"} [200]
/readyz         -> {"status":"ok"} [200]
/c/x/sessions   -> 401
```

The flag is inert in an artifact that could be deployed.

## DoD status

1. "the flag is refused when `MAJADU_ENV=prod`": **satisfied**. The debug build
   refuses it (transcript above) and refuses an https redirect or a secure
   cookie with it; `apps/api/tests/server_test.nim` covers all three.
2. "`/readyz` is served by the real handler only, and the stub returns 503 for
   it": **partly**. `/readyz` exists only in the real handler, so a stub can
   never answer it successfully. The stub answers 404, not 503. The status is
   left as it is: changing it needs `apps/api/src/server.nim`, and any status
   outside 2xx fails a probe, so the safety property holds.
3. "a test asserts that a test-routes instance fails `/readyz`": **satisfied**
   by `tools/qa/stub_router_test.nim` (not 2xx), plus the end-to-end half in
   `e2e/api.spec.ts`, which starts the release binary with the flag and asserts
   the real routes answer.

## Permanent checks

- `tools/qa/stub_router_test.nim` calls the stub router directly: `/readyz` is
  not 2xx, `/healthz` names the stub rather than claiming the API is ok, and no
  data route exists.
- `e2e/api.spec.ts` ("MAJADU_TEST_ROUTES cannot degrade a release build") uses
  the second instance `./task e2e` starts with the flag and asserts `/healthz`
  is `ok`, `/readyz` is 200 and a data route is 401 rather than 404.
