import std/[json, os, unittest]
import db/db
import ../http_support

const
  baseUrl = "http://127.0.0.1:18099"
  port = Port(18099)

var database: Db

proc bootstrap() =
  database = openDb(dsn(), 1)
  discard database.execUpdate("delete from platform.cutover_state")
  startServer(newTestApp(database), port, baseUrl)

bootstrap()

suite "readiness":
  test "a fresh install with no cutover row is ready":
    delEnv("CUTOVER_SNAPSHOT_SHA256")
    let status = call(baseUrl, HttpGet, "/readyz")
    let body = status.body
    expectStatus(status, 200)
    check parseJson(body)["status"].getStr() == "ok"

  test "a recorded snapshot only blocks when the process expects another":
    discard database.execUpdate(
      """insert into platform.cutover_state (id, snapshot_sha256)
         values (true, 'aaaa')""")
    delEnv("CUTOVER_SNAPSHOT_SHA256")
    expectStatus(call(baseUrl, HttpGet, "/readyz"), 200)

    putEnv("CUTOVER_SNAPSHOT_SHA256", "aaaa")
    expectStatus(call(baseUrl, HttpGet, "/readyz"), 200)

    putEnv("CUTOVER_SNAPSHOT_SHA256", "bbbb")
    let status = call(baseUrl, HttpGet, "/readyz")
    let body = status.body
    expectProblem(status, 503)
    check parseJson(body)["code"].getStr() == "NOT_READY"
    check parseJson(body)["detail"].getStr() ==
      "database holds a different snapshot"

    delEnv("CUTOVER_SNAPSHOT_SHA256")
    discard database.execUpdate("delete from platform.cutover_state")
