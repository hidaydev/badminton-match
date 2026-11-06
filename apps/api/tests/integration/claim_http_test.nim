import std/[httpclient, json, options, os, strutils, unittest]
import mummy
import db/db
import sha256
import ../../src/app
import account/infrastructure/oidc
import account/infrastructure/session_store
import community/infrastructure/community_store
import platform/config/store
import share/crypto

const
  baseUrl = "http://127.0.0.1:18096"
  port = Port(18096)
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
  communityId: string
  adminCookie, admin2Cookie, memberCookie, otherCookie: string
  adminId: string

proc dsn(): string = getEnv("MAJADU_PG_DSN")

proc call(verb: HttpMethod, path, cookie = "", body = ""): (int, string) =
  let client = newHttpClient(timeout = 5000)
  defer: client.close()
  var headers = newHttpHeaders()
  headers["Origin"] = "http://127.0.0.1:5173"
  if cookie.len > 0:
    headers["Cookie"] = "majadu_session=" & cookie
  if body.len > 0:
    headers["Content-Type"] = "application/json"
  let response = client.request(baseUrl & path, httpMethod = verb,
    headers = headers, body = body)
  (response.code.int, response.body)

proc freshMember(sub: string): string =
  let id = database.queryOne(
    """insert into platform.user (google_sub, email_hash, display_name)
       values ($1, $1, $1)
       on conflict (google_sub) do update set display_name = excluded.display_name
       returning id""", @[textParam(sub)]).get.get("id")
  discard database.execUpdate(
    """insert into community.membership (community_id, user_id, role)
       values ($1::uuid, $2::uuid, 'member')
       on conflict (community_id, user_id) do nothing""",
    @[textParam(communityId), textParam(id)])
  createSession(database, id, 30)

proc player(name: string): string =
  let (status, body) = call(HttpPost, "/c/claim-club/players", adminCookie,
    "{\"name\":\"" & name & "\"}")
  doAssert status == 201, body
  parseJson(body)["id"].getStr()

proc bootstrap() =
  database = openDb(dsn(), 1)
  discard database.execUpdate(
    """delete from player.claims where community_id in
         (select id from platform.community where slug = 'claim-club')""")
  discard database.execUpdate(
    """delete from player.players where community_id in
         (select id from platform.community where slug = 'claim-club')""")
  discard database.execUpdate(
    "delete from platform.community where slug = 'claim-club'")
  discard database.execUpdate(
    "delete from platform.user where google_sub like 'claim-%'")
  let ownerId = database.queryOne(
    """insert into platform.user (google_sub, email_hash, display_name, is_platform_owner)
       values ('claim-owner', 'claim-owner-hash', 'Owner', true) returning id"""
    ).get.get("id")
  communityId = community_store.create(database, "claim-club", "Claim Club",
    "claim-admin@example.com", "Asia/Jakarta", ownerId).communityId
  proc member(sub, role: string): string =
    let id = database.queryOne(
      """insert into platform.user (google_sub, email_hash, display_name)
         values ($1, $1, $1) returning id""", @[textParam(sub)]).get.get("id")
    discard database.execUpdate(
      """insert into community.membership (community_id, user_id, role)
         values ($1::uuid, $2::uuid, $3)""",
      @[textParam(communityId), textParam(id), textParam(role)])
    id
  adminId = member("claim-admin", "admin")
  let admin2Id = member("claim-admin2", "admin")
  let memberId = member("claim-member", "member")
  let otherId = member("claim-other", "member")
  adminCookie = createSession(database, adminId, 30)
  admin2Cookie = createSession(database, admin2Id, 30)
  memberCookie = createSession(database, memberId, 30)
  otherCookie = createSession(database, otherId, 30)

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
  doAssert up, "api did not start on port 18096"

bootstrap()

suite "claim HTTP":
  test "a claim is pending, single while pending, and decided by an admin":
    let playerId = player("Klaim Satu")
    let (submitted, _) = call(HttpPost,
      "/c/claim-club/players/" & playerId & "/claims", memberCookie)
    check submitted == 201
    let (duplicate, _) = call(HttpPost,
      "/c/claim-club/players/" & playerId & "/claims", otherCookie)
    check duplicate == 409
    let (list, listBody) = call(HttpGet,
      "/c/claim-club/players/" & playerId & "/claims", adminCookie)
    check list == 200
    let claimId = parseJson(listBody)["items"][0]["id"].getStr()
    let (byMember, _) = call(HttpPatch,
      "/c/claim-club/players/" & playerId & "/claims/" & claimId, memberCookie,
      """{"decision":"approve"}""")
    check byMember == 403
    let (approved, _) = call(HttpPatch,
      "/c/claim-club/players/" & playerId & "/claims/" & claimId, adminCookie,
      """{"decision":"approve"}""")
    check approved == 200
    let (bound, boundBody) = call(HttpGet,
      "/c/claim-club/players/" & playerId, adminCookie)
    check bound == 200
    check parseJson(boundBody)["userId"].kind == JString

  test "an admin cannot decide a claim they filed":
    let playerId = player("Klaim Dua")
    let (submitted, _) = call(HttpPost,
      "/c/claim-club/players/" & playerId & "/claims", admin2Cookie)
    check submitted == 201
    let (_, listBody) = call(HttpGet,
      "/c/claim-club/players/" & playerId & "/claims", adminCookie)
    let claimId = parseJson(listBody)["items"][0]["id"].getStr()
    let (selfDecision, _) = call(HttpPatch,
      "/c/claim-club/players/" & playerId & "/claims/" & claimId, admin2Cookie,
      """{"decision":"approve"}""")
    check selfDecision == 403

  test "only one pending claim exists per player":
    let playerId = player("Klaim Tiga")
    let first = freshMember("claim-tiga-a")
    let second = freshMember("claim-tiga-b")
    let (accepted, _) = call(HttpPost,
      "/c/claim-club/players/" & playerId & "/claims", first)
    check accepted == 201
    let (queuedBehind, _) = call(HttpPost,
      "/c/claim-club/players/" & playerId & "/claims", second)
    check queuedBehind == 409
    let (_, listBody) = call(HttpGet,
      "/c/claim-club/players/" & playerId & "/claims", adminCookie)
    let items = parseJson(listBody)["items"]
    check items.len == 1
    let claimId = items[0]["id"].getStr()
    discard call(HttpPatch, "/c/claim-club/players/" & playerId & "/claims/" &
      claimId, adminCookie, """{"decision":"approve"}""")
    # Once claimed, nobody else can even file.
    let (afterApproval, _) = call(HttpPost,
      "/c/claim-club/players/" & playerId & "/claims", second)
    check afterApproval == 409

  test "the owner can release and another account can claim again":
    let playerId = player("Klaim Empat")
    let owner = freshMember("claim-empat")
    discard call(HttpPost, "/c/claim-club/players/" & playerId & "/claims", owner)
    let (_, listBody) = call(HttpGet,
      "/c/claim-club/players/" & playerId & "/claims", adminCookie)
    let claimId = parseJson(listBody)["items"][0]["id"].getStr()
    discard call(HttpPatch, "/c/claim-club/players/" & playerId & "/claims/" &
      claimId, adminCookie, """{"decision":"approve"}""")
    let (released, releasedBody) = call(HttpDelete,
      "/c/claim-club/players/" & playerId & "/claim", owner)
    check released == 200
    check parseJson(releasedBody)["status"].getStr() == "released"
    let (unbound, unbindBody) = call(HttpGet,
      "/c/claim-club/players/" & playerId, adminCookie)
    check unbindBody.contains("\"userId\":null")
    let (again, _) = call(HttpPost,
      "/c/claim-club/players/" & playerId & "/claims",
      freshMember("claim-empat-again"))
    check again == 201

  test "an admin release needs a reason and reports a stale claim as 409":
    let playerId = player("Klaim Lima")
    discard call(HttpPost, "/c/claim-club/players/" & playerId & "/claims",
      freshMember("claim-lima"))
    let (_, listBody) = call(HttpGet,
      "/c/claim-club/players/" & playerId & "/claims", adminCookie)
    let claimId = parseJson(listBody)["items"][0]["id"].getStr()
    discard call(HttpPatch, "/c/claim-club/players/" & playerId & "/claims/" &
      claimId, adminCookie, """{"decision":"approve"}""")
    let (noReason, _) = call(HttpPatch, "/c/claim-club/players/" & playerId &
      "/claims/" & claimId, adminCookie, """{"action":"release"}""")
    check noReason == 400
    let (released, _) = call(HttpPatch, "/c/claim-club/players/" & playerId &
      "/claims/" & claimId, adminCookie,
      """{"action":"release","reason":"account transfer"}""")
    check released == 200
    let (twice, _) = call(HttpPatch, "/c/claim-club/players/" & playerId &
      "/claims/" & claimId, adminCookie,
      """{"action":"release","reason":"again"}""")
    check twice == 409

  test "a second approval for the same member closes instead of dangling":
    let claimant = freshMember("claim-two-players")
    let firstPlayer = player("Klaim Empat A")
    let secondPlayer = player("Klaim Empat B")
    discard call(HttpPost, "/c/claim-club/players/" & firstPlayer & "/claims",
      claimant)
    discard call(HttpPost, "/c/claim-club/players/" & secondPlayer & "/claims",
      claimant)
    let (_, firstList) = call(HttpGet,
      "/c/claim-club/players/" & firstPlayer & "/claims", adminCookie)
    let firstClaim = parseJson(firstList)["items"][0]["id"].getStr()
    let (firstApproved, _) = call(HttpPatch,
      "/c/claim-club/players/" & firstPlayer & "/claims/" & firstClaim,
      adminCookie, """{"decision":"approve"}""")
    check firstApproved == 200

    let (_, secondList) = call(HttpGet,
      "/c/claim-club/players/" & secondPlayer & "/claims", adminCookie)
    let secondClaim = parseJson(secondList)["items"][0]["id"].getStr()
    let (refused, refusedBody) = call(HttpPatch,
      "/c/claim-club/players/" & secondPlayer & "/claims/" & secondClaim,
      adminCookie, """{"decision":"approve"}""")
    check refused == 409
    check parseJson(refusedBody)["code"].getStr() == "CLAIMANT_OWNS_PLAYER"
    # The refused claim is closed, so it cannot stay pending forever.
    let (_, afterList) = call(HttpGet,
      "/c/claim-club/players/" & secondPlayer & "/claims", adminCookie)
    check parseJson(afterList)["items"][0]["status"].getStr() == "rejected"
    check parseJson(afterList)["items"][0]["reason"].getStr() == "already_claimed"

  test "a member sees the claim trail without another member's identity":
    let playerId = player("Klaim Enam")
    let applicant = freshMember("claim-enam-a")
    let bystander = freshMember("claim-enam-b")
    discard call(HttpPost, "/c/claim-club/players/" & playerId & "/claims",
      applicant)
    let (_, adminList) = call(HttpGet,
      "/c/claim-club/players/" & playerId & "/claims", adminCookie)
    let claimId = parseJson(adminList)["items"][0]["id"].getStr()
    let (approved, _) = call(HttpPatch, "/c/claim-club/players/" & playerId &
      "/claims/" & claimId, adminCookie,
      """{"decision":"approve","reason":"verified at the club"}""")
    check approved == 200

    # The filing member still recognises their own decision and reason.
    let (_, ownBody) = call(HttpGet,
      "/c/claim-club/players/" & playerId & "/claims", applicant)
    let own = parseJson(ownBody)["items"][0]
    check own["userId"].getStr().len > 0
    check own["decidedBy"].getStr().len > 0
    check own["reason"].getStr() == "verified at the club"

    # Anyone else sees that the player is claimed, not who claimed it.
    let (otherStatus, otherBody) = call(HttpGet,
      "/c/claim-club/players/" & playerId & "/claims", bystander)
    check otherStatus == 200
    let seen = parseJson(otherBody)["items"][0]
    check seen["id"].getStr() == claimId
    check seen["status"].getStr() == "approved"
    check seen["userId"].getStr() == ""
    check seen["decidedBy"].getStr() == ""
    check seen["reason"].getStr() == ""
