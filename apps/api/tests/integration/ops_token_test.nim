import std/[httpclient, json, options, os, strutils, unittest]
import mummy
import db/db
import ../../src/app
import account/infrastructure/oidc
import account/infrastructure/ops_token
import account/infrastructure/session_store
import platform/config/store
import share/crypto

const
  baseUrl = "http://127.0.0.1:18097"
  port = Port(18097)
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

var
  database: Db
  ownerId: string
  ownerCookie, token, expiredToken: string

proc dsn(): string = getEnv("MAJADU_PG_DSN")

proc call(path, header = "", cookie = ""): (int, string) =
  let client = newHttpClient(timeout = 5000)
  defer: client.close()
  var headers = newHttpHeaders()
  if header.len > 0:
    headers["Authorization"] = header
  if cookie.len > 0:
    headers["Cookie"] = "majadu_session=" & cookie
  let response = client.request(baseUrl & path, httpMethod = HttpGet,
    headers = headers)
  (response.code.int, response.body)

proc bootstrap() =
  database = openDb(dsn(), 1)
  discard database.execUpdate("delete from platform.ops_token")
  discard database.execUpdate("delete from platform.user where google_sub = 'ops-owner'")
  ownerId = database.queryOne(
    """insert into platform.user (google_sub, email_hash, display_name, is_platform_owner)
       values ('ops-owner', 'ops-owner-hash', 'Ops Owner', true) returning id"""
    ).get.get("id")
  ownerCookie = createSession(database, ownerId, 30)
  token = ops_token.issue(database, "ci", ownerId, 30)
  expiredToken = ops_token.issue(database, "old", ownerId, 30)
  discard database.execUpdate(
    """update platform.ops_token set expires_at = now() - interval '1 minute'
       where name = 'old'""")

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
  doAssert up, "api did not start on port 18097"

bootstrap()

suite "ops token":
  test "the bearer token opens an ops route":
    let (status, body) = call("/ops/ping", header = "Bearer " & token)
    check status == 200
    check parseJson(body)["ok"].getBool()

  test "a browser cookie does not open an ops route":
    let (status, _) = call("/ops/ping", cookie = ownerCookie)
    check status == 401

  test "the same token does not authenticate web routes":
    let (me, _) = call("/auth/me", header = "Bearer " & token)
    check me == 401

  test "an expired token is rejected":
    let (status, _) = call("/ops/ping", header = "Bearer " & expiredToken)
    check status == 401

  test "a revoked token stops working":
    discard ops_token.revokeToken(database,
      database.queryOne("select id from platform.ops_token where name = 'ci'"
        ).get.get("id"))
    let (status, _) = call("/ops/ping", header = "Bearer " & token)
    check status == 401
