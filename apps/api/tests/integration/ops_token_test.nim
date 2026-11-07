import std/[json, options, unittest]
import db/db
import account/infrastructure/ops_token
import tests/fixtures
import ../http_support

const
  port = testPort(18095)
  baseUrl = "http://127.0.0.1:" & $uint16(port)

var
  database: Db
  ownerId: string
  ownerCookie, token, expiredToken: string

proc bootstrap() =
  database = openDb(dsn(), 1)
  discard database.execUpdate("delete from platform.ops_token")
  discard database.execUpdate("delete from platform.user where google_sub = 'ops-owner'")
  ownerId = newUser(database, "ops-owner", "ops-owner@example.com", "Ops Owner",
    owner = true)
  ownerCookie = cookieFor(database, ownerId)
  token = ops_token.issue(database, "ci", ownerId, 30)
  expiredToken = ops_token.issue(database, "old", ownerId, 30)
  discard database.execUpdate(
    """update platform.ops_token set expires_at = now() - interval '1 minute'
       where name = 'old'""")

  startServer(newTestApp(database), port, baseUrl)

bootstrap()

suite "ops token":
  test "the bearer token opens an ops route":
    let response = call(baseUrl, HttpGet, "/ops/ping",
      extra = [("Authorization", "Bearer " & token)])
    expectStatus(response, 200)
    check response.json["ok"].getBool()

  test "a browser cookie does not open an ops route":
    expectProblem(call(baseUrl, HttpGet, "/ops/ping", ownerCookie), 401)

  test "the same token does not authenticate web routes":
    expectProblem(call(baseUrl, HttpGet, "/auth/me",
      extra = [("Authorization", "Bearer " & token)]), 401)

  test "an expired token is rejected":
    expectProblem(call(baseUrl, HttpGet, "/ops/ping",
      extra = [("Authorization", "Bearer " & expiredToken)]), 401)

  test "a revoked token stops working":
    discard ops_token.revokeToken(database,
      database.queryOne("select id from platform.ops_token where name = 'ci'"
        ).get.get("id"))
    expectProblem(call(baseUrl, HttpGet, "/ops/ping",
      extra = [("Authorization", "Bearer " & token)]), 401)
