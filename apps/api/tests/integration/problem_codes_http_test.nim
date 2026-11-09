## One reachability case per problem code `app.nim` can emit.
##
## The table is grouped by family, and each row asserts the status, the code,
## the envelope's `i18nKey` and the problem content type: a handler branch that
## drifts from its contract fails here even when the branch still answers.
##
## Five codes are not rows on purpose, with the reason recorded next to the
## guard at the bottom: `INTERNAL` is the boundary fallback with no route of its
## own, `USER_UPSERT_FAILED` and `INVALID_SESSION` sit behind an `insert ...
## returning` that cannot return no row, `MERGE_CONFLICT` needs a schema-level
## conflict no fixture reaches, and `UNAVAILABLE` is a pool checkout or a full
## rating queue. Everything else is driven through the route that emits it, with
## its own fixture.

import std/[base64, exitprocs, httpclient, json, net, options, os, osproc,
            strutils, times, unittest, uri]
import mummy
import db/db
import sha256
import account/infrastructure/oidc
import share/crypto
import platform/config/store
import tests/fixtures
import tournament/domain/classic
import tournament/domain/classic_draw
import ../http_support
import ../../src/app
import errors

let
  port = testPort()
  baseUrl = "http://127.0.0.1:" & $uint16(port)

const
  oidcPort = 18179
  oidcBase = "http://127.0.0.1:" & $oidcPort
  clientId = "be19-client"
  slug = "be19-club"
  keyPath = "tools/oidc-stub/test_key.pem"
  jwksPath = "tools/oidc-stub/jwks.json"
  badTokenEmail = "be19-bad-token@example.com"
  exchangeFailEmail = "be19-exchange-fail@example.com"
  anonSub = "be19-anon-sub"

var
  database: Db
  communityId: string
  exercised: seq[string]
  ownerCookie, adminCookie, hostCookie, memberCookie, memberBCookie,
    memberCCookie, memberDCookie: string
  adminId, memberAId, memberBId: string
  p1, p2, p3, p4, p5, pAliasA, pAliasB, pClaimFree, pOwnedByB, pOwnedByA,
    m1, m2, m3, pSessionFree: string
  sessDefault, sessClassic, sessDraft: string

proc b64url(data: string): string =
  result = encode(data)
  result = result.replace('+', '-').replace('/', '_')
  result = result.strip(chars = {'='})

proc b64urlDecode(data: string): string =
  var padded = data.replace('-', '+').replace('_', '/')
  while padded.len mod 4 != 0:
    padded.add('=')
  decode(padded)

proc signToken(payload: string): string =
  let dir = getTempDir() / ("be19-sign-" & $getCurrentProcessId())
  createDir(dir)
  let inputPath = dir / "input"
  let sigPath = dir / "signature"
  try:
    writeFile(inputPath, payload)
    let (output, code) = execCmdEx("openssl dgst -sha256 -sign " &
      quoteShell(keyPath) & " -out " & quoteShell(sigPath) & " " &
      quoteShell(inputPath))
    if code != 0:
      raise newException(IOError, output)
    b64url(readFile(sigPath))
  finally:
    removeFile(inputPath)
    removeFile(sigPath)
    removeDir(dir)

proc issueToken(sub, email, nonce: string): string =
  let now = getTime().toUnix
  let header = %*{"alg": "RS256", "kid": "test-1", "typ": "JWT"}
  let claims = %*{
    "iss": oidcBase, "aud": clientId, "sub": sub, "email": email,
    "email_verified": true, "nonce": nonce, "iat": now, "exp": now + 3600}
  let signingInput = b64url($header) & "." & b64url($claims)
  signingInput & "." & signToken(signingInput)

proc oidcHandle(request: Request) {.gcsafe.} =
  case request.path
  of "/jwks":
    request.respond(200, @[("Content-Type", "application/json")],
      readFile(jwksPath))
  of "/token":
    var code = ""
    for (key, value) in decodeQuery(request.body):
      if key == "code":
        code = value
    var claims: JsonNode
    try:
      claims = parseJson(b64urlDecode(code))
    except CatchableError:
      request.respond(400, @[("Content-Type", "application/json")],
        """{"error":"invalid_grant"}""")
      return
    let email = claims["email"].getStr()
    if email == exchangeFailEmail:
      request.respond(400, @[("Content-Type", "application/json")],
        """{"error":"invalid_grant"}""")
      return
    if email == badTokenEmail:
      request.respond(200, @[("Content-Type", "application/json")],
        """{"id_token":"not-a-jwt"}""")
      return
    let token = issueToken(claims["sub"].getStr(), email,
      claims["nonce"].getStr())
    request.respond(200, @[("Content-Type", "application/json")],
      $(%*{"id_token": token, "token_type": "Bearer", "expires_in": 3600}))
  else:
    request.respond(404, @[("Content-Type", "application/json")],
      """{"error":"not_found"}""")

type
  OidcArgs = object
    server: Server
    port: Port

  ApiArgs = object
    server: Server
    port: Port

proc apiServe(args: ApiArgs) {.thread.} =
  try:
    args.server.serve(args.port, "127.0.0.1")
  except MummyError:
    discard

proc startApiWithHeadroom(app: App, transportCap: int) =
  ## mummy refuses a body past its own `maxBodyLen` before any handler runs, so
  ## the transport cap is lifted past the configured limit and the 413 case is
  ## answered by `rejectLargeBody`, which is the branch under test.
  install(app)
  let server = newServer(handler(), workerThreads = 4,
    maxBodyLen = transportCap)
  var thread: Thread[ApiArgs]
  createThread(thread, apiServe, ApiArgs(server: server, port: Port(port)))
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
  doAssert up, "api did not start on port " & $uint16(port)

proc oidcServe(args: OidcArgs) {.thread.} =
  try:
    args.server.serve(args.port, "127.0.0.1")
  except MummyError:
    discard

proc startOidc() =
  let server = newServer(oidcHandle, workerThreads = 2)
  var thread: Thread[OidcArgs]
  createThread(thread, oidcServe, OidcArgs(server: server, port: Port(oidcPort)))
  var up = false
  for _ in 0 ..< 100:
    try:
      let client = newHttpClient(timeout = 1000)
      defer: client.close()
      if client.get(oidcBase & "/jwks").code.int == 200:
        up = true
        break
    except CatchableError:
      discard
    sleep(50)
  doAssert up, "test OIDC server did not start"

proc versionOf(sessionId: string): int =
  database.queryOne(
    "select version from session.sessions where id = $1::uuid",
    @[textParam(sessionId)]).get.getInt("version")

proc makeSession(preset: string): string =
  var body = %*{"title": "BE19 session " & preset, "date": "2026-11-20",
    "startTime": "18:00"}
  if preset.len > 0:
    body["scoringPreset"] = %preset
  let response = call(baseUrl, HttpPost, "/c/" & slug & "/sessions", hostCookie,
    $body)
  doAssert response.status == 201, response.body
  response.json["id"].getStr()

proc scheduleOneGame(sessionId: string) =
  let body = %*{"games": [{"round": 0, "court": 0,
    "sideA": [p1, p2], "sideB": [p3, p4]}]}
  let response = call(baseUrl, HttpPut, "/c/" & slug & "/sessions/" & sessionId &
    "/schedule", hostCookie, $body, ifMatch = $versionOf(sessionId))
  doAssert response.status == 200, response.body

proc requireRow(label, verb: string, path, cookie, body: string, status: int,
                code: string, detail = "", ifMatch = "",
                origin = allowedOrigin,
                extra: openArray[(string, string)] = []) =
  ## One checkpoint per code: the envelope shape, not only the status.
  let httpVerb = case verb
    of "GET": HttpGet
    of "POST": HttpPost
    of "PUT": HttpPut
    of "PATCH": HttpPatch
    of "DELETE": HttpDelete
    else: HttpGet
  let response = call(baseUrl, httpVerb, path, cookie, body, origin = origin,
    ifMatch = ifMatch, extra = extra)
  checkpoint(label & ": " & response.body)
  check response.status == status
  check response.header("Content-Type") == "application/problem+json"
  if response.status != status:
    return
  let node = parseJson(response.body)
  check node["status"].getInt() == status
  check node["code"].getStr() == code
  check node["i18nKey"].getStr() == i18nKeyFor(code)
  if detail.len > 0:
    check node["detail"].getStr() == detail
  if code notin exercised:
    exercised.add(code)

proc classicBody(): JsonNode =
  var pairs: seq[Pair] = @[]
  for index in 1 .. 16:
    pairs.add(Pair(id: "p" & $index,
      name: "P" & $(index * 2 - 1) & " & P" & $(index * 2)))
  let data = generateTournament("BE19 Cup", "2026-11-21", pairs, 11)
  var items = newJArray()
  for pair in data.pairs:
    items.add(%*{"id": pair.id, "name": pair.name})
  var groups = newJObject()
  for groupId in GroupIds:
    var members = newJArray()
    for pairId in data.groups[ord(groupId)]:
      members.add(%pairId)
    groups[$groupId] = members
  var matches = newJArray()
  for match in data.matches:
    matches.add(%*{
      "id": match.id, "phase": $match.phase,
      "groupId": if match.groupId.isSome: %($match.groupId.get) else: newJNull(),
      "pairAId": if match.pairAId.isSome: %match.pairAId.get else: newJNull(),
      "pairBId": if match.pairBId.isSome: %match.pairBId.get else: newJNull(),
      "scoreA": if match.scoreA.isSome: %match.scoreA.get else: newJNull(),
      "scoreB": if match.scoreB.isSome: %match.scoreB.get else: newJNull()})
  %*{"name": data.name, "date": data.date, "pairs": items, "groups": groups,
     "matches": matches}

proc startFlow(): tuple[state, nonce: string] =
  let response = call(baseUrl, HttpPost, "/auth/start",
    body = """{"returnTo":"/"}""")
  doAssert response.status == 200, response.body
  let url = response.json["authorizeUrl"].getStr()
  (queryParam(url, "state"), queryParam(url, "nonce"))

proc encodeCode(sub, email, nonce: string): string =
  b64url($(%*{"sub": sub, "email": email, "nonce": nonce}))

proc callback(state, code: string, withCookie = true,
              maxRedirects = 0): HttpResult =
  var headers: seq[(string, string)] = @[]
  if withCookie:
    headers.add(("Cookie", "majadu_auth_flow=" & sha256Hex(state)))
  call(baseUrl, HttpGet,
    "/auth/callback?code=" & encodeUrl(code) & "&state=" & encodeUrl(state),
    extra = headers, maxRedirects = maxRedirects)

proc bootstrap() =
  requireDatabase()
  database = openDb(dsn(), 1)
  purgeCommunity(database, slug)
  cleanupUsers(database, "be19-%")
  # The anonymised identity stores sha256(sub); the cleanup above cannot match
  # it, so this run removes the fixed one it creates.
  discard database.execUpdate(
    "delete from platform.user where google_sub = $1",
    @[textParam(sha256Hex(anonSub))])

  let ownerId = newUser(database, "be19-owner", "be19-owner@example.com",
    "BE19 Owner", owner = true)
  adminId = newUser(database, "be19-admin", "be19-admin@example.com",
    "BE19 Admin")
  memberAId = newUser(database, "be19-a", "be19-a@example.com", "BE19 A")
  let hostId = newUser(database, "be19-host", "be19-host@example.com",
    "BE19 Host")
  memberBId = newUser(database, "be19-b", "be19-b@example.com", "BE19 B")
  let memberCId = newUser(database, "be19-c", "be19-c@example.com", "BE19 C")
  let memberDId = newUser(database, "be19-d", "be19-d@example.com", "BE19 D")
  communityId = newCommunity(database, slug, "BE19 Club")
  newMember(database, communityId, adminId, "admin")
  newMember(database, communityId, hostId, "host")
  newMember(database, communityId, memberAId, "member")
  newMember(database, communityId, memberBId, "member")
  newMember(database, communityId, memberCId, "member")
  newMember(database, communityId, memberDId, "member")
  ownerCookie = cookieFor(database, ownerId)
  adminCookie = cookieFor(database, adminId)
  hostCookie = cookieFor(database, hostId)
  memberCookie = cookieFor(database, memberAId)
  memberBCookie = cookieFor(database, memberBId)
  memberCCookie = cookieFor(database, memberCId)
  memberDCookie = cookieFor(database, memberDId)

  p1 = newPlayer(database, communityId, "Be19 One", userId = "")
  p2 = newPlayer(database, communityId, "Be19 Two")
  p3 = newPlayer(database, communityId, "Be19 Three")
  p4 = newPlayer(database, communityId, "Be19 Four")
  p5 = newPlayer(database, communityId, "Be19 Five")
  pAliasA = newPlayer(database, communityId, "Be19 Alias A")
  pAliasB = newPlayer(database, communityId, "Be19 Alias B")
  pClaimFree = newPlayer(database, communityId, "Be19 Claim Free")
  pOwnedByB = newPlayer(database, communityId, "Be19 Owned B",
    userId = memberBId)
  pOwnedByA = newPlayer(database, communityId, "Be19 Owned A",
    userId = memberAId)
  pSessionFree = newPlayer(database, communityId, "Be19 Session Free")
  m1 = newPlayer(database, communityId, "Be19 Merge One")
  m2 = newPlayer(database, communityId, "Be19 Merge Two")
  m3 = newPlayer(database, communityId, "Be19 Merge Partner")

  startOidc()
  let oidc = OidcConfig(authorizeUrl: oidcBase & "/authorize",
    tokenUrl: oidcBase & "/token", jwksUrl: oidcBase & "/jwks",
    issuer: oidcBase, clientId: clientId,
    redirectUri: "http://127.0.0.1:5173/api/auth/callback")
  startApiWithHeadroom(newApp(database, oidc, loadKeyring(keysJson, "1"),
    newConfigCache(database)), 2_000_000)

  sessDefault = makeSession("")
  sessClassic = makeSession("classic21")
  sessDraft = makeSession("")
  scheduleOneGame(sessDefault)
  scheduleOneGame(sessClassic)

bootstrap()

suite "problem-code reachability: guards":
  test "the request guards answer their own codes":
    requireRow("unauth", "GET", "/c/" & slug & "/players", "", "", 401,
      "UNAUTHENTICATED", "login required")
    requireRow("gate", "POST", "/c/" & slug & "/players", memberCookie,
      """{"name":"Be19 Nope"}""", 403, "FORBIDDEN", "FORBIDDEN")
    requireRow("route", "GET", "/be19-no-route", "", "", 404, "NOT_FOUND",
      "route not found")
    requireRow("method", "DELETE", "/version", "", "", 405, "METHOD")
    requireRow("csrf", "POST", "/auth/start", "", """{"returnTo":"/"}""",
      403, "CSRF_REJECTED", "origin is not allowed",
      origin = "http://evil.example")
    requireRow("outdated", "GET", "/directory", "", "", 410, "CLIENT_OUTDATED",
      "this client speaks an older contract; reload the page",
      extra = [("X-API-Version", "999.0")])
    requireRow("large", "POST", "/auth/start", "", repeat('x', 1_100_000),
      413, "BODY_TOO_LARGE", "request body exceeds the limit")

  test "every rejection carries no-store, not only the 204s and the 429s":
    # SEC-11: 404 and 410 are heuristically cacheable and a 429 carries
    # Retry-After, which a shared cache may honour. The API sits behind a CDN
    # and a rewrite, so a refusal must never be served from one.
    let notFound = call(baseUrl, HttpGet, "/be19-no-route")
    expectStatus(notFound, 404)
    check header(notFound, "Cache-Control") == "no-store"
    let forbidden = call(baseUrl, HttpPost, "/c/" & slug & "/players",
      memberCookie, """{"name":"Be19 Cached"}""")
    expectStatus(forbidden, 403)
    check header(forbidden, "Cache-Control") == "no-store"
    # `memberC` has its own join budget, so the throttle below is deterministic
    # whichever order the cases before this one ran in.
    for _ in 0 .. 4:
      discard call(baseUrl, HttpPost, "/c/" & slug & "/join-requests",
        memberCCookie)
    let limited = call(baseUrl, HttpPost, "/c/" & slug & "/join-requests",
      memberCCookie)
    expectStatus(limited, 429)
    check header(limited, "Cache-Control") == "no-store"

  test "the join limiter answers RATE_LIMITED on the sixth request":
    for _ in 0 .. 4:
      discard call(baseUrl, HttpPost, "/c/" & slug & "/join-requests",
        memberDCookie)
    requireRow("ratelimited", "POST", "/c/" & slug & "/join-requests",
      memberDCookie, "", 429, "RATE_LIMITED", "too many requests")

  test "a snapshot mismatch on readyz answers NOT_READY":
    discard database.execUpdate("delete from platform.cutover_state")
    discard database.execUpdate(
      """insert into platform.cutover_state (id, snapshot_sha256)
         values (true, 'be19-recorded')""")
    putEnv("CUTOVER_SNAPSHOT_SHA256", "be19-expected")
    try:
      requireRow("readyz", "GET", "/readyz", "", "", 503, "NOT_READY",
        "database holds a different snapshot")
    finally:
      delEnv("CUTOVER_SNAPSHOT_SHA256")
      discard database.execUpdate("delete from platform.cutover_state")

suite "problem-code reachability: communities and invites":
  test "community create refusals":
    requireRow("slug", "POST", "/communities", ownerCookie,
      """{"slug":"be19-club","name":"Again","adminEmail":"x@example.com"}""",
      409, "SLUG_TAKEN", "community slug already exists")
    requireRow("invalid", "POST", "/communities", ownerCookie,
      """{"slug":"a/b","name":"Bad","adminEmail":"x@example.com"}""",
      400, "INVALID_COMMUNITY")

  test "member and join-request refusals":
    requireRow("role", "PATCH", "/c/" & slug & "/members/" & adminId,
      adminCookie, """{"role":"nope"}""", 400, "INVALID_ROLE",
      "role must be member, host or admin")
    requireRow("lastadmin", "PATCH", "/c/" & slug & "/members/" & adminId,
      adminCookie, """{"role":"member"}""", 409, "LAST_ADMIN",
      "promote another admin first")
    requireRow("member404", "PATCH", "/c/" & slug & "/members/" &
      "00000000-0000-0000-0000-000000000001", adminCookie,
      """{"role":"host"}""", 404, "NOT_FOUND", "member not found")
    requireRow("decision", "PATCH", "/c/" & slug & "/join-requests/" &
      "00000000-0000-0000-0000-000000000002", adminCookie,
      """{"decision":"maybe"}""", 400, "INVALID_DECISION",
      "decision must be approve or reject")

  test "invite refusals":
    requireRow("email", "POST", "/c/" & slug & "/invites", adminCookie,
      """{"email":"not-an-email"}""", 400, "INVALID_EMAIL",
      "a valid email is required")

    let used = call(baseUrl, HttpPost, "/c/" & slug & "/invites", adminCookie,
      """{"email":"be19-b@example.com","role":"host"}""")
    doAssert used.status == 201, used.body
    let usedToken = used.json["token"].getStr()
    let accepted = call(baseUrl, HttpPost, "/invites/" & usedToken & "/accept",
      memberBCookie)
    doAssert accepted.status == 201, accepted.body
    # The membership the invitation granted is removed, so the second
    # redemption is "already used" instead of the idempotent replay a current
    # member gets.
    let removed = call(baseUrl, HttpDelete, "/c/" & slug & "/members/" &
      memberBId, adminCookie)
    doAssert removed.status == 204, removed.body
    requireRow("used", "POST", "/invites/" & usedToken & "/accept", memberBCookie,
      "", 410, "INVITE_USED", "invitation was already used")

    let expired = call(baseUrl, HttpPost, "/c/" & slug & "/invites",
      adminCookie, """{"email":"be19-d@example.com"}""")
    doAssert expired.status == 201, expired.body
    let expiredToken = expired.json["token"].getStr()
    discard database.execUpdate(
      """update community.invite set expires_at = now() - interval '1 minute'
         where community_id = $1::uuid and expires_at is not null""",
      @[textParam(communityId)])
    # The first invite above is already accepted; only the new one is pending.
    discard database.execUpdate(
      """update community.invite set expires_at = now() - interval '1 minute'
         where community_id = $1::uuid and accepted_at is null""",
      @[textParam(communityId)])
    requireRow("expired", "POST", "/invites/" & expiredToken & "/accept",
      memberDCookie, "", 410, "INVITE_EXPIRED", "invitation has expired")
    requireRow("unknown", "POST", "/invites/deadbeef/accept", memberDCookie,
      "", 404, "INVITE_NOT_FOUND", "invitation not found")

    let mismatch = call(baseUrl, HttpPost, "/c/" & slug & "/invites",
      adminCookie, """{"email":"be19-d@example.com"}""")
    doAssert mismatch.status == 201, mismatch.body
    let mismatchToken = mismatch.json["token"].getStr()
    requireRow("mismatch", "POST", "/invites/" & mismatchToken & "/accept",
      memberCCookie, "", 403, "INVITE_EMAIL_MISMATCH",
      "invitation belongs to another address")

suite "problem-code reachability: players and claims":
  test "player refusals":
    requireRow("invalid", "POST", "/c/" & slug & "/players", hostCookie,
      """{"name":""}""", 400, "INVALID_PLAYER")
    requireRow("alias", "POST", "/c/" & slug & "/players", hostCookie,
      """{"name":"Be19 Bad Alias","aliases":["x","x"]}""", 400,
      "INVALID_ALIAS", "aliases must be distinct non-empty names")
    requireRow("exists", "POST", "/c/" & slug & "/players", hostCookie,
      """{"name":"Be19 One"}""", 409, "PLAYER_EXISTS",
      "a player with this name already exists")

    let withAlias = call(baseUrl, HttpPost, "/c/" & slug & "/players",
      hostCookie, """{"name":"Be19 Alias Owner","aliases":["be19-shared"]}""")
    doAssert withAlias.status == 201, withAlias.body
    requireRow("aliastaken", "POST", "/c/" & slug & "/players", hostCookie,
      """{"name":"Be19 Alias Thief","aliases":["be19-shared"]}""", 409,
      "ALIAS_TAKEN", "an alias is already used by another player")

    requireRow("same", "POST", "/c/" & slug & "/players/" & m1 & "/merge",
      adminCookie, "{\"sourcePlayerId\":\"" & m1 & "\"}", 400,
      "SAME_PLAYER", "source and target must differ")

  test "merge collision refusals":
    let mergeSession = makeSession("")
    let body = %*{"games": [{"round": 5, "court": 1,
      "sideA": [m1], "sideB": [m2]}]}
    let scheduled = call(baseUrl, HttpPut, "/c/" & slug & "/sessions/" &
      mergeSession & "/schedule", hostCookie, $body,
      ifMatch = $versionOf(mergeSession))
    doAssert scheduled.status == 200, scheduled.body
    requireRow("session", "POST", "/c/" & slug & "/players/" & m1 & "/merge",
      adminCookie, "{\"sourcePlayerId\":\"" & m2 & "\"}", 409,
      "MERGE_SESSION_CONFLICT",
      "both players appear in the same game; edit that game first")
    discard database.execUpdate(
      "delete from session.games where community_id = $1::uuid and round_no = 5",
      @[textParam(communityId)])

    let tournament = database.queryOne(
      """insert into tournament.tournaments (community_id, name)
         values ($1::uuid, 'BE19 Merge Cup') returning id""",
      @[textParam(communityId)]).get.getUuid("id")
    discard database.execUpdate(
      """insert into tournament.pairs
           (community_id, tournament_id, display_name, player_a_id, player_b_id)
         values ($1::uuid, $2::uuid, 'M1 & Partner', $3::uuid, $5::uuid),
                ($1::uuid, $2::uuid, 'M2 & Partner', $4::uuid, $5::uuid)""",
      @[textParam(communityId), textParam(tournament), textParam(m1),
        textParam(m2), textParam(m3)])
    requireRow("pair", "POST", "/c/" & slug & "/players/" & m1 & "/merge",
      adminCookie, "{\"sourcePlayerId\":\"" & m2 & "\"}", 409,
      "MERGE_PAIR_CONFLICT",
      "both players already have a pair with the same partner")

  test "claim refusals":
    let pending = call(baseUrl, HttpPost, "/c/" & slug & "/players/" &
      pClaimFree & "/claims", memberCCookie)
    doAssert pending.status == 201, pending.body
    requireRow("pending", "POST", "/c/" & slug & "/players/" & pClaimFree &
      "/claims", memberDCookie, "", 409, "CLAIM_PENDING",
      "a claim for this player is pending")
    requireRow("claimed", "POST", "/c/" & slug & "/players/" & pOwnedByB &
      "/claims", memberCCookie, "", 409, "CLAIMED",
      "this player already has an owner")
    requireRow("owns", "POST", "/c/" & slug & "/players/" & pSessionFree &
      "/claims", memberCookie, "", 409, "CLAIMANT_OWNS_PLAYER",
      "this member already has a player in this community")
    let pendingClaimId = database.queryOne(
      """select id from player.claims where community_id = $1::uuid
         and player_id = $2::uuid and status = 'pending'""",
      @[textParam(communityId), textParam(pClaimFree)]).get.getUuid("id")
    let adminClaimPlayer = newPlayer(database, communityId, "Be19 Admin Claim")
    let adminClaim = call(baseUrl, HttpPost, "/c/" & slug & "/players/" &
      adminClaimPlayer & "/claims", adminCookie)
    doAssert adminClaim.status == 201, adminClaim.body
    let claimId = database.queryOne(
      """select id from player.claims where community_id = $1::uuid
         and player_id = $2::uuid and user_id = $3::uuid""",
      @[textParam(communityId), textParam(adminClaimPlayer),
        textParam(adminId)]).get.getUuid("id")
    requireRow("selfdecision", "PATCH", "/c/" & slug & "/players/" &
      adminClaimPlayer & "/claims/" & claimId, adminCookie,
      """{"decision":"approve"}""", 403, "SELF_DECISION",
      "you cannot decide your own claim")
    requireRow("reason", "PATCH", "/c/" & slug & "/players/" &
      pClaimFree & "/claims/" & pendingClaimId, adminCookie,
      """{"action":"release"}""", 400, "REASON_REQUIRED",
      "releasing someone else needs a reason")
    requireRow("conflict", "DELETE", "/c/" & slug & "/players/" & p1 &
      "/claim", memberCCookie, "", 409, "CLAIM_CONFLICT",
      "you have no approved claim here")
    requireRow("claim404", "PATCH", "/c/" & slug & "/players/" & p1 &
      "/claims/00000000-0000-0000-0000-000000000003", adminCookie,
      """{"decision":"approve"}""", 404, "NOT_FOUND", "claim not found")

suite "problem-code reachability: sessions and schedule":
  test "body and precondition refusals":
    requireRow("body", "POST", "/c/" & slug & "/sessions", hostCookie,
      """{"title":"   ","date":"2026-11-20"}""", 400, "INVALID_BODY",
      "title must not be blank")
    requireRow("preset", "POST", "/c/" & slug & "/sessions", hostCookie,
      """{"title":"Be19 Preset","date":"2026-11-20","scoringPreset":"nope"}""",
      400, "INVALID_PRESET", "unknown scoring preset")
    requireRow("patch", "PATCH", "/c/" & slug & "/sessions/" & sessDefault,
      hostCookie, """{"slotMinutes":0}""", 400, "INVALID_PATCH",
      "slotMinutes must be between 1 and 240",
      ifMatch = $versionOf(sessDefault))
    requireRow("precondition", "PATCH", "/c/" & slug & "/sessions/" &
      sessDefault, hostCookie, """{"title":"Be19 New"}""", 428,
      "PRECONDITION_REQUIRED", "If-Match is required")
    requireRow("badprecondition", "PATCH", "/c/" & slug & "/sessions/" &
      sessDefault, hostCookie, """{"title":"Be19 New"}""", 400,
      "INVALID_PRECONDITION", "If-Match must be a version number",
      ifMatch = "abc")
    requireRow("stale", "PATCH", "/c/" & slug & "/sessions/" & sessDefault,
      hostCookie, """{"title":"Be19 New"}""", 412, "STALE_VERSION",
      "session changed since If-Match", ifMatch = "999999")

  test "swap and schedule refusals":
    requireRow("swap", "POST", "/c/" & slug & "/sessions/" & sessDefault &
      "/swap", hostCookie, "{}", 400, "INVALID_SWAP",
      "swap type must be player|team|slot",
      ifMatch = $versionOf(sessDefault))
    requireRow("schedule", "PUT", "/c/" & slug & "/sessions/" & sessDefault &
      "/schedule", hostCookie, "{}", 400, "INVALID_SCHEDULE",
      "body must contain a games array",
      ifMatch = $versionOf(sessDefault))
    requireRow("unknownplayer", "PUT", "/c/" & slug & "/sessions/" &
      sessDefault & "/schedule", hostCookie,
      """{"games":[{"round":0,"court":1,"sideA":["00000000-0000-0000-0000-000000000004"],"sideB":[]}]}""",
      400, "UNKNOWN_PLAYER", "player is not in this community",
      ifMatch = $versionOf(sessDefault))
    requireRow("notparticipant", "PATCH", "/c/" & slug & "/sessions/" &
      sessDefault & "/absent", hostCookie,
      "{\"playerIds\":[\"" & p5 & "\"]}", 400, "NOT_PARTICIPANT",
      "player is not in this session", ifMatch = $versionOf(sessDefault))
    requireRow("gamekey", "GET", "/c/" & slug & "/sessions/" & sessDefault &
      "/games/abc", hostCookie, "", 400, "INVALID_GAME_KEY",
      "gameKey must be round-court")

  test "score and format refusals":
    let gamePath = "/c/" & slug & "/sessions/" & sessDefault & "/games/0-0"
    requireRow("score", "PATCH", gamePath, hostCookie,
      """{"scoreA":30,"scoreB":30}""", 400, "INVALID_SCORE",
      "set 1: scores cannot be equal", ifMatch = $versionOf(sessDefault))
    requireRow("sequence", "PATCH", gamePath, hostCookie,
      """{"sets":[{"a":30,"b":10},{"a":30,"b":10}]}""", 400,
      "INVALID_SET_SEQUENCE", "too many sets for this format",
      ifMatch = $versionOf(sessDefault))
    requireRow("setsrequired", "PATCH", "/c/" & slug & "/sessions/" &
      sessClassic & "/games/0-0", hostCookie,
      """{"scoreA":21,"scoreB":10}""", 400, "SETS_REQUIRED",
      "this format needs set scores, not a single score",
      ifMatch = $versionOf(sessClassic))

    let scored = call(baseUrl, HttpPatch, gamePath, hostCookie,
      """{"sets":[{"a":30,"b":10}]}""", ifMatch = $versionOf(sessDefault))
    doAssert scored.status == 200, scored.body
    requireRow("hassets", "PATCH", gamePath, hostCookie,
      """{"played":true}""", 409, "MATCH_HAS_SETS",
      "clear the recorded sets before marking the match played",
      ifMatch = $versionOf(sessDefault))
    requireRow("presetlocked", "PATCH", "/c/" & slug & "/sessions/" &
      sessDefault, hostCookie, """{"scoringPreset":"classic21"}""", 409,
      "PRESET_LOCKED", "clear the recorded sets before changing the format",
      ifMatch = $versionOf(sessDefault))

  test "idempotency and websocket refusals":
    let first = call(baseUrl, HttpPost, "/c/" & slug & "/sessions", hostCookie,
      """{"title":"Be19 Idem One","date":"2026-11-20"}""",
      extra = [("Idempotency-Key", "be19-idem")])
    doAssert first.status == 201, first.body
    requireRow("idempotency", "POST", "/c/" & slug & "/sessions", hostCookie,
      """{"title":"Be19 Idem Two","date":"2026-11-21"}""", 409,
      "IDEMPOTENCY_CONFLICT", "this key was used with a different body",
      extra = [("Idempotency-Key", "be19-idem")])

    # A live claim with no stored response: another request owns the key.
    let inFlightKey = "be19-inflight"
    let inFlightBody = """{"title":"Be19 In Flight","date":"2026-11-22"}"""
    discard database.execUpdate(
      """insert into platform.idempotency_keys (user_id, key, body_hash, expires_at)
         values ((select id from platform.user where google_sub = 'be19-host'),
                 $1, $2, now() + interval '1 hour')""",
      @[textParam(communityId & ":" & inFlightKey),
        textParam(sha256Hex(inFlightBody))])
    requireRow("inprogress", "POST", "/c/" & slug & "/sessions", hostCookie,
      inFlightBody, 409, "IDEMPOTENCY_IN_PROGRESS",
      "this key is still being processed; retry shortly",
      extra = [("Idempotency-Key", inFlightKey)])
    discard database.execUpdate(
      "delete from platform.idempotency_keys where key = $1",
      @[textParam(communityId & ":" & inFlightKey)])

    requireRow("wsunauth", "GET", "/ws/share/be19-deadbeef", "", "", 401,
      "UNAUTHENTICATED", "ticket is invalid, expired or already used")
    requireRow("ws404", "GET", "/ws/c/" & slug & "/sessions/" &
      "00000000-0000-0000-0000-000000000005", "", "", 404, "NOT_FOUND",
      "session not found")

    let ticket = call(baseUrl, HttpPost, "/c/" & slug & "/sessions/" &
      sessDefault & "/ws-ticket", memberCookie)
    doAssert ticket.status == 200, ticket.body
    requireRow("upgrade", "GET", "/ws/c/" & slug & "/sessions/" & sessDefault &
      "?ticket=" & ticket.json["ticket"].getStr(), "", "", 400,
      "UPGRADE_REQUIRED", "websocket upgrade required")

suite "problem-code reachability: config, rating and tournaments":
  test "config refusals":
    requireRow("unknown", "PATCH", "/c/" & slug & "/settings", adminCookie,
      """{"nope.value":1}""", 400, "UNKNOWN_CONFIG_KEY")
    requireRow("platform", "PATCH", "/c/" & slug & "/settings", adminCookie,
      """{"security.max_body_bytes":2048}""", 400, "PLATFORM_CONFIG_KEY")
    requireRow("ceiling", "PATCH", "/c/" & slug & "/settings", adminCookie,
      """{"rating.score_target":50}""", 400, "OVERRIDE_TOO_HIGH")
    requireRow("type", "PATCH", "/c/" & slug & "/settings", adminCookie,
      """{"rating.score_target":"high"}""", 400, "INVALID_CONFIG_VALUE")

  test "rating refusals":
    requireRow("conflict", "POST", "/c/" & slug & "/sessions/" & sessDraft &
      "/rating", adminCookie, "", 409, "CONFLICT",
      "session is not approved")
    requireRow("notrated", "PATCH", "/c/" & slug & "/rating-sources/" &
      sessDraft, adminCookie, """{"finalized":true}""", 409, "NOT_RATED",
      "session has no rating to sign off")
    requireRow("eventsource", "DELETE", "/c/" & slug & "/rating-sources/" &
      "00000000-0000-0000-0000-000000000006", adminCookie, "", 404,
      "NOT_FOUND", "rating event not found")

  test "share refusals":
    # SEC-09: a code may only name an approved session, and the refusal names
    # the status instead of minting a link for an unfinished session.
    requireRow("draftshare", "POST", "/c/" & slug & "/sessions/" & sessDraft &
      "/share", adminCookie, "", 409, "SESSION_NOT_SHAREABLE",
      "session status is draft; only an approved session is shareable")

  test "tournament refusals":
    requireRow("invalid", "POST", "/c/" & slug & "/tournaments", hostCookie,
      "{}", 400, "INVALID_TOURNAMENT", "tournament body is invalid")

    let created = call(baseUrl, HttpPost, "/c/" & slug & "/tournaments",
      hostCookie, $classicBody())
    doAssert created.status == 201, created.body
    let tournamentId = created.json["id"].getStr()
    requireRow("state", "POST", "/c/" & slug & "/tournaments/" &
      tournamentId & "/rating", adminCookie, "", 400, "INVALID_STATE",
      "tournament must be finalized before rating")
    requireRow("stale", "PUT", "/c/" & slug & "/tournaments/" & tournamentId,
      hostCookie, $classicBody(), 412, "STALE_VERSION",
      "tournament changed since If-Match", ifMatch = "999999")
    requireRow("missing", "GET", "/c/" & slug & "/tournaments/" &
      "00000000-0000-0000-0000-000000000007", hostCookie, "", 404,
      "NOT_FOUND", "tournament not found")

suite "problem-code reachability: auth flow":
  test "callback refusals":
    requireRow("callback", "GET", "/auth/callback", "", "", 400,
      "INVALID_CALLBACK", "code and state are required")
    requireRow("state", "GET", "/auth/callback?code=x&state=y", "", "", 400,
      "INVALID_STATE", "flow not found, expired or already used")

  test "a broken verifier is a key error":
    let (state, _) = startFlow()
    discard database.execUpdate(
      """update auth.oauth_flows set code_verifier_enc = decode('deadbeef','hex')
         where state_hash = decode($1,'hex')""", @[textParam(sha256Hex(state))])
    requireRow("key", "GET", "/auth/callback?code=" & encodeUrl("x") &
      "&state=" & encodeUrl(state), "", "", 500, "KEY_ERROR",
      "cannot decrypt flow",
      extra = [("Cookie", "majadu_auth_flow=" & sha256Hex(state))])

  test "a refused token exchange is a bad request":
    let (state, nonce) = startFlow()
    let code = encodeCode("be19-sub", exchangeFailEmail, nonce)
    requireRow("exchange", "GET", "/auth/callback?code=" &
      encodeUrl(code) & "&state=" & encodeUrl(state), "", "", 400,
      "TOKEN_EXCHANGE_FAILED", "token exchange failed",
      extra = [("Cookie", "majadu_auth_flow=" & sha256Hex(state))])

  test "a malformed or wrongly signed token is an invalid id token":
    let (state, nonce) = startFlow()
    let code = encodeCode("be19-sub", badTokenEmail, nonce)
    requireRow("idtoken", "GET", "/auth/callback?code=" &
      encodeUrl(code) & "&state=" & encodeUrl(state), "", "", 401,
      "INVALID_ID_TOKEN", "id token is invalid",
      extra = [("Cookie", "majadu_auth_flow=" & sha256Hex(state))])

  test "a token for another nonce is a nonce mismatch":
    let (state, _) = startFlow()
    let code = encodeCode("be19-sub", "be19-sub@example.com", "wrong-nonce")
    requireRow("nonce", "GET", "/auth/callback?code=" &
      encodeUrl(code) & "&state=" & encodeUrl(state), "", "", 401,
      "NONCE_MISMATCH", "nonce mismatch",
      extra = [("Cookie", "majadu_auth_flow=" & sha256Hex(state))])

  test "a login for an anonymised subject is refused":
    let anonId = newUser(database, anonSub, "be19-anon@example.com", "Anon")
    discard database.execUpdate(
      "update platform.user set google_sub = $1, email_hash = $2 where id = $3::uuid",
      @[textParam(sha256Hex(anonSub)),
        textParam(sha256Hex("anonymized:" & anonId)), textParam(anonId)])
    let (state, nonce) = startFlow()
    let code = encodeCode(anonSub, "be19-anon@example.com", nonce)
    requireRow("anonymized", "GET", "/auth/callback?code=" &
      encodeUrl(code) & "&state=" & encodeUrl(state), "", "", 403,
      "ACCOUNT_ANONYMIZED", "this account was deactivated",
      extra = [("Cookie", "majadu_auth_flow=" & sha256Hex(state))])

suite "problem-code static guard":
  test "every literal code is a row or has a recorded reason":
    # Codes this table cannot reach, with the reason. A new literal in app.nim
    # fails this case until it joins the table or this list. `covered` is not a
    # second list: it is the codes `requireRow` actually exercised above, so
    # deleting a row also deletes its claim to coverage.
    const unreachable = ["INTERNAL", "USER_UPSERT_FAILED", "INVALID_SESSION",
      "MERGE_CONFLICT", "UNAVAILABLE"]
    # INTERNAL: boundary fallback for an unexpected SQLSTATE, no route of its
    # own. USER_UPSERT_FAILED and INVALID_SESSION: after an insert ... returning
    # that cannot return no row. MERGE_CONFLICT: fallback for an integrity
    # violation; no fixture reaches it without a schema-level conflict.
    # UNAVAILABLE: a pool checkout (DbPoolTimeout) or a full rating queue, both
    # of which need a fixture the suite cannot hold deterministically.

    var missing: seq[string] = @[]
    let text = readFile("apps/api/src/app.nim")
    let marker = "problem(request"
    var cursor = 0
    while true:
      let found = text.find(marker, cursor)
      if found < 0:
        break
      cursor = found + marker.len
      var index = cursor
      while index < text.len and text[index] in {' ', ','}:
        inc index
      var digits = 0
      while index < text.len and text[index] in {'0' .. '9'}:
        inc index
        inc digits
      while index < text.len and text[index] in {' ', ','}:
        inc index
      if digits == 0 or index >= text.len or text[index] != '"':
        continue
      let closing = text.find('"', index + 1)
      if closing < 0:
        continue
      let code = text[index + 1 ..< closing]
      if code.len > 0 and code[0] in {'A' .. 'Z'} and
          code notin exercised and code notin unreachable:
        missing.add(code)
    checkpoint("codes with no executed row: " & $missing)
    check missing.len == 0
    # The reverse direction: a row that names no literal in app.nim would hide a
    # stale case, so it is reported too.
    var stale: seq[string] = @[]
    for code in exercised:
      if code notin unreachable and not text.contains("\"" & code & "\""):
        stale.add(code)
    checkpoint("rows with no literal: " & $stale)
    check stale.len == 0