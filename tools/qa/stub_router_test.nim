## QAE-03: the stub router must never look ready.
##
## `MAJADU_TEST_ROUTES=1` replaces the whole application with a skeleton that
## answers `/healthz`. A release build compiles the flag out, and a debug build
## refuses it beside any production signal; both are covered in
## `apps/api/tests/server_test.nim`. What nothing asserted is the property an
## orchestrator depends on: the stub is not ready. `/readyz` is absent from the
## stub's route table, so it falls through to the 404 branch and a readiness
## probe reads that as a failure.
##
## The assertion is "not 2xx", not "503", so the day the stub answers an explicit
## 503 the check stays green. The end-to-end half of the finding (a release
## build ignoring the flag) runs in `e2e/api.spec.ts`, because it needs a booted
## process and this suite must not bind a port.

import std/[json, unittest]
import api/src/server

suite "QAE-03: the test-route stub cannot pass a readiness probe":
  test "the stub does not answer /readyz with a success":
    let outcome = route("/readyz", testRoutes = true)
    check outcome.status < 200 or outcome.status > 299

  test "the stub health names itself instead of claiming the API is ok":
    let outcome = route("/healthz", testRoutes = true)
    check outcome.status == 200
    check parseJson(outcome.body)["status"].getStr() == "stub"

  test "the real router answers /healthz as ok":
    let outcome = route("/healthz", testRoutes = false)
    check outcome.status == 200
    check parseJson(outcome.body)["status"].getStr() == "ok"

  test "every data route the audit probed is absent from the stub":
    for path in ["/version", "/directory", "/c/acme/sessions"]:
      check route(path, testRoutes = true).status == 404
