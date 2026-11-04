import std/[httpclient, json, os, strutils, unittest]
import mummy
import db/db
import ../../src/app
import account/infrastructure/oidc
import platform/config/store
import share/crypto

const
  baseUrl = "http://127.0.0.1:18099"
  port = Port(18099)
  keysJson = """{"1":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="}"""

type
  ServeArgs = object
    server: Server
    port: Port

proc serveThread(args: ServeArgs) {.thread.} =
  try:
    args.server.serve(args.port, "127.0.0.1")
  except MummyError:
    discard

var database: Db

proc dsn(): string = getEnv("MAJADU_PG_DSN")

proc call(path: string): (int, string) =
  let client = newHttpClient(timeout = 5000)
  defer: client.close()
  let response = client.get(baseUrl & path)
  (response.code.int, response.body)

proc bootstrap() =
  database = openDb(dsn(), 1)
  discard database.execUpdate("delete from platform.cutover_state")
  install(newApp(database, OidcConfig(), loadKeyring(keysJson, "1"),
    newConfigCache(database)))
  let server = newServer(handler(), workerThreads = 4)
  var thread: Thread[ServeArgs]
  createThread(thread, serveThread, ServeArgs(server: server, port: port))
  var up = false
  for _ in 0 ..< 200:
    try:
      let client = newHttpClient(timeout = 1000)
      defer: client.close()
      if client.get(baseUrl & "/healthz").code.int == 200:
        up = true
        break
    except CatchableError:
      discard
    sleep(50)
  doAssert up, "api did not start on port 18099"

bootstrap()

suite "readiness":
  test "a fresh install with no cutover row is ready":
    delEnv("CUTOVER_SNAPSHOT_SHA256")
    let (status, body) = call("/readyz")
    check status == 200
    check parseJson(body)["status"].getStr() == "ok"

  test "a recorded snapshot only blocks when the process expects another":
    discard database.execUpdate(
      """insert into platform.cutover_state (id, snapshot_sha256)
         values (true, 'aaaa')""")
    delEnv("CUTOVER_SNAPSHOT_SHA256")
    check call("/readyz")[0] == 200

    putEnv("CUTOVER_SNAPSHOT_SHA256", "aaaa")
    check call("/readyz")[0] == 200

    putEnv("CUTOVER_SNAPSHOT_SHA256", "bbbb")
    let (status, body) = call("/readyz")
    check status == 503
    check parseJson(body)["code"].getStr() == "NOT_READY"
    check parseJson(body)["detail"].getStr() ==
      "database holds a different snapshot"

    delEnv("CUTOVER_SNAPSHOT_SHA256")
    discard database.execUpdate("delete from platform.cutover_state")
