import std/[httpclient, json, strutils, unittest]
import db/db
import mummy
import ../http_support

const
  baseUrl = "http://127.0.0.1:18105"
  port = Port(18105)

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
      let response = call(baseUrl, HttpGet, "/healthz")
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
    expectStatus(call(baseUrl, HttpGet, "/readyz"), 200)
    # A different client address keeps its own bucket on the same route.
    expectStatus(call(baseUrl, HttpGet, "/healthz",
      extra = [("X-Client-IP", "203.0.113.9")]), 200)
