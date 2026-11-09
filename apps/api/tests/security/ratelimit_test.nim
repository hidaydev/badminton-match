import std/[httpclient, json, strutils, unittest]
import db/db
import mummy
import tests/fixtures
import ../http_support

const
  port = testPort(18101)
  baseUrl = "http://127.0.0.1:" & $uint16(port)

var database: Db

proc bootstrap() =
  database = openDb(dsn(), 1)
  startServer(newTestApp(database), port, baseUrl)

requireDatabase()

bootstrap()

suite "security: rate limit":
  test "v1-red/v2-green: exceeding the route limit returns 429 with Retry-After":
    var blocked: HttpResult
    var allowed = 0
    for _ in 0 ..< 400:
      let response = call(baseUrl, HttpGet, "/version")
      if response.status == 200:
        inc allowed
      else:
        blocked = response
        break
    check allowed >= 299
    expectStatus(blocked, 429)
    check blocked.json["status"].getInt() == 429
    check blocked.json["code"].getStr() == "RATE_LIMITED"
    check blocked.header("Retry-After").len > 0
    check parseInt(blocked.header("Retry-After")) >= 1

    # A different route keeps its own bucket.
    expectStatus(call(baseUrl, HttpGet, "/ops/ping"), 401)
    # A different client address keeps its own bucket on the same route.
    expectStatus(call(baseUrl, HttpGet, "/version",
      extra = [("X-Client-IP", "203.0.113.9")]), 200)

  test "random unknown session cookies stay in the address bucket":
    # SEC-01/QAE-01: a cookie is only an identity once the database confirms
    # it. Every request below carries a different forged value from the same
    # address, so the address budget must still stop it.
    var blocked: HttpResult
    var allowed = 0
    for index in 0 ..< 400:
      let response = call(baseUrl, HttpGet, "/version",
        cookie = "forged-" & $index,
        extra = [("X-Client-IP", "198.51.100.23")])
      if response.status == 200:
        inc allowed
      else:
        blocked = response
        break
    check allowed >= 299
    expectStatus(blocked, 429)
    check blocked.json["code"].getStr() == "RATE_LIMITED"

  test "minting share buckets cannot reset the exhausted address budget":
    # B2/D-?: exhaust `/auth/start` for an address, then mint one share bucket
    # per random code. The old limiter evicted the least recently seen bucket
    # carrying that address, which was the exhausted `/auth/start` budget, and
    # the next rebuild got a fresh 300.
    let address = "198.51.100.51"
    var exhausted = false
    for _ in 0 ..< 400:
      let response = call(baseUrl, HttpPost, "/auth/start", body = "{}",
        extra = [("X-Client-IP", address)])
      if response.status == 429:
        exhausted = true
        break
    check exhausted
    for index in 0 ..< 17:
      discard call(baseUrl, HttpGet, "/s/random" & $index,
        extra = [("X-Client-IP", address)])
    let afterChurn = call(baseUrl, HttpPost, "/auth/start", body = "{}",
      extra = [("X-Client-IP", address)])
    expectStatus(afterChurn, 429)

  test "two sessions of one user share the join-request bucket":
    # SEC-01 DoD, second half: a per-account budget cannot be multiplied by
    # logging in twice. Both cookies resolve to the same user id, so the sixth
    # join request is 429 whichever session sends it.
    cleanupUsers(database, "ratelimit-join%")
    let userId = newUser(database, "ratelimit-join",
      "ratelimit-join@example.com", "Rate Limit Join")
    let first = cookieFor(database, userId)
    let second = cookieFor(database, userId)
    var blocked: HttpResult
    var allowed = 0
    for index in 0 ..< 6:
      let cookie = if index mod 2 == 0: first else: second
      let response = call(baseUrl, HttpPost,
        "/c/ratelimit-join-none/join-requests", cookie, "{}")
      if response.status == 202:
        inc allowed
      else:
        blocked = response
    check allowed == 5
    expectStatus(blocked, 429)

  test "random cookies stop causing identity lookups after the pre-limit":
    # B3: the pre-limit is charged before `account.sessions` is read, so after
    # its budget the answer is a 429 with no query. Before the fix every one of
    # these requests bought one indexed SELECT even though it was rejected.
    let address = "198.51.100.41"
    let before = identityLookups()
    var plateau = 0
    var last = before
    var requests = 0
    for index in 0 ..< 2000:
      discard call(baseUrl, HttpGet, "/version",
        cookie = "forged-lookup-" & $index,
        extra = [("X-Client-IP", address)])
      inc requests
      let current = identityLookups()
      if current == last:
        inc plateau
        if plateau >= 25:
          break
      else:
        plateau = 0
        last = current
    check plateau >= 25
    check requests > 300
    # The budget is spent on a finite number of lookups, not one per request.
    check last - before >= 300
    check last - before < 2000

  test "a genuine session keeps one bucket across addresses":
    # The validated cookie is the identity, so rotating the address header must
    # not reset the budget for a signed-in caller either.
    discard database.execUpdate(
      """delete from account.sessions where user_id in
           (select id from platform.user where google_sub = 'ratelimit-session')""")
    discard database.execUpdate(
      "delete from platform.user where google_sub = 'ratelimit-session'")
    let userId = newUser(database, "ratelimit-session",
      "ratelimit-session@example.com", "Rate Limit")
    let cookie = cookieFor(database, userId)
    let lookupsBefore = identityLookups()
    var blocked: HttpResult
    var allowed = 0
    for index in 0 ..< 400:
      let address =
        if index mod 2 == 0: "192.0.2.10" else: "192.0.2.11"
      let response = call(baseUrl, HttpGet, "/version", cookie = cookie,
        extra = [("X-Client-IP", address)])
      if response.status == 200:
        inc allowed
      else:
        blocked = response
        break
    check allowed >= 299
    expectStatus(blocked, 429)
    # One validation served every request: the address headers rotate but the
    # cache keeps the token-to-user mapping, and the budget stays per user.
    check identityLookups() - lookupsBefore <= 1
