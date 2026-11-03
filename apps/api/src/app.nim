import std/[base64, json, options, os, strutils, sysrand, times, uri]
import mummy
import db/db
import sha256
import uuidv7
import share/crypto
import account/domain/audit
import account/infrastructure/audit_store
import account/infrastructure/jwt_rs256
import account/infrastructure/oidc
import account/infrastructure/session_store
import platform/config/store

type
  App* = ref object
    db*: Db
    oidc*: OidcConfig
    keyring*: Keyring
    config*: ConfigCache
    cookieSecure*: bool
    bootstrapOwner*: string

  AuthUser = object
    id*: string
    emailHash*: string
    displayName*: string
    isOwner*: bool

var application: App

proc randomHex*(count: int): string =
  var bytes = newSeq[byte](count)
  if not urandom(bytes):
    raise newException(IOError, "cannot read random bytes")
  for value in bytes:
    result.add(toHex(value, 2).toLowerAscii)

proc hexBytes*(value: string): seq[byte] =
  if value.len mod 2 != 0:
    raise newException(ValueError, "odd hex length")
  result = newSeq[byte](value.len div 2)
  for index in 0 ..< result.len:
    result[index] = byte(parseHexInt(value[index * 2 .. index * 2 + 1]))

proc bytesHex*(value: seq[byte]): string =
  for byteValue in value:
    result.add(toHex(byteValue, 2).toLowerAscii)

proc b64url*(value: string): string =
  encode(value).replace('+', '-').replace('/', '_').strip(chars = {'='})

proc b64url*(value: openArray[byte]): string =
  var raw = newString(value.len)
  for index in 0 ..< value.len:
    raw[index] = char(value[index])
  b64url(raw)

proc audit(action: string, communityId: string, user: AuthUser,
           targetKind: string, targetId: string,
           after: JsonNode = newJObject()) =
  ## Every privileged write leaves evidence. Field names outside the domain
  ## allowlist are dropped inside the adapter, never written.
  recordAudit(application.db, auditEvent(action, communityId,
    actorId = user.id, actorRole = (if user.isOwner: "platform_owner" else: "admin"),
    targetKind = targetKind, targetId = targetId, requestId = uuidv7()).withEvidence(
      newJObject(), after))

proc jsonResponse(request: Request, status: int, body: JsonNode,
                  extra: openArray[(string, string)] = []) =
  var headers = @[("Content-Type", "application/json")]
  for pair in extra:
    headers.add(pair)
  request.respond(status, headers, $body)

proc problem(request: Request, status: int, code, detail: string) =
  request.respond(status, @[("Content-Type", "application/json")],
    $ %*{"status": status, "code": code, "detail": detail})

proc bodyJson(request: Request): JsonNode =
  if request.body.len == 0:
    return %*{}
  try:
    parseJson(request.body)
  except JsonParsingError:
    raise newException(ValueError, "invalid JSON body")

proc cookieValue(request: Request, name: string): string =
  let header = request.headers["Cookie"]
  for part in header.split(';'):
    let pair = part.strip().split('=', maxsplit = 1)
    if pair.len == 2 and pair[0] == name:
      return pair[1]
  ""

proc configSnapshot(): Snapshot =
  application.config.snapshot(application.db)

proc sessionCookie(token: string): string =
  let days = configSnapshot().intValue(%*{}, keySessionAbsoluteDays)
  result = "majadu_session=" & token &
    "; Path=/; HttpOnly; SameSite=Lax; Max-Age=" & $(days * 86400)
  if application.cookieSecure:
    result.add("; Secure")

proc setSessionCookie(request: Request, token: string) =
  var cookie = "majadu_session=" & token & "; Path=/; HttpOnly; SameSite=Lax; Max-Age=2592000"
  if application.cookieSecure:
    cookie.add("; Secure")
  request.respond(204, @[("Set-Cookie", cookie)], "")

proc createSessionToken(userId: string): string =
  let days = configSnapshot().intValue(%*{}, keySessionAbsoluteDays)
  createSession(application.db, userId, days)

proc currentUser(request: Request): Option[AuthUser] =
  let token = cookieValue(request, "majadu_session")
  if token.len == 0:
    return none(AuthUser)
  let idleDays = configSnapshot().intValue(%*{}, keySessionIdleDays)
  let user = resolve(application.db, token, idleDays)
  if user.isNone:
    return none(AuthUser)
  some(AuthUser(
    id: user.get.userId,
    emailHash: user.get.emailHash,
    displayName: user.get.displayName,
    isOwner: user.get.isPlatformOwner,
  ))

proc requireUser(request: Request): Option[AuthUser] =
  result = currentUser(request)
  if result.isNone:
    problem(request, 401, "UNAUTHENTICATED", "login required")

type CommunityCtx = object
  id: string
  slug: string
  role: string

proc resolveCommunity(user: AuthUser, slug: string): Option[CommunityCtx] =
  let row = application.db.queryOne(
    """select c.id, c.slug, coalesce(m.role, '') as role
       from platform.community c
       left join community.membership m
         on m.community_id = c.id and m.user_id = $2
       where c.slug = $1""",
    @[textParam(slug), textParam(user.id)])
  if row.isNone:
    return none(CommunityCtx)
  let value = row.get
  let role = value.get("role")
  if role.len == 0 and not user.isOwner:
    return none(CommunityCtx)
  some(CommunityCtx(id: value.get("id"), slug: value.get("slug"), role: role))

proc canWrite(ctx: CommunityCtx, user: AuthUser): bool =
  user.isOwner or ctx.role in ["host", "admin"]

proc authorizeUrl(config: OidcConfig, state, nonce, challenge: string): string =
  let separator = if '?' in config.authorizeUrl: "&" else: "?"
  config.authorizeUrl & separator &
    "client_id=" & encodeUrl(config.clientId) &
    "&redirect_uri=" & encodeUrl(config.redirectUri) &
    "&response_type=code&scope=openid%20email%20profile" &
    "&state=" & encodeUrl(state) &
    "&nonce=" & encodeUrl(nonce) &
    "&code_challenge=" & encodeUrl(challenge) &
    "&code_challenge_method=S256"

proc startAuth(request: Request) =
  let body = bodyJson(request)
  let returnTo =
    if body.hasKey("returnTo"): body["returnTo"].getStr() else: "/"
  let safeReturn = if returnTo.startsWith("/") and not returnTo.startsWith("//"): returnTo else: "/"
  let state = randomHex(32)
  let nonce = randomHex(32)
  let verifier = randomHex(32)
  let challenge = b64url(sha256Raw(verifier))
  let (keyId, encrypted) = encryptWith(application.keyring, verifier, state)
  let ttl = configSnapshot().intValue(%*{}, keyAuthFlowTtlMinutes)
  discard application.db.execUpdate(
    """insert into auth.oauth_flows
       (state_hash, nonce_hash, code_verifier_enc, return_to, expires_at)
       values (decode($1,'hex'), decode($2,'hex'), decode($3,'hex'), $4,
               now() + make_interval(mins => $5))""",
    @[textParam(sha256Hex(state)), textParam(sha256Hex(nonce)),
      textParam(bytesHex(encrypted)), textParam(safeReturn), intParam(ttl.int64)])
  jsonResponse(request, 200, %*{
    "authorizeUrl": authorizeUrl(application.oidc, state, nonce, challenge),
    "keyId": keyId,
  })

proc finishAuth(request: Request) =
  let code = request.queryParams["code"]
  let state = request.queryParams["state"]
  if code.len == 0 or state.len == 0:
    problem(request, 400, "INVALID_CALLBACK", "code and state are required")
    return
  # One-shot read: the row is deleted even when the tokens below fail, so a
  # replayed callback can never reuse a flow. Expiry is evaluated by the database.
  let row = application.db.queryOne(
    """with deleted as (
         delete from auth.oauth_flows
         where state_hash = decode($1,'hex') and expires_at > now()
         returning nonce_hash, code_verifier_enc, return_to)
       select encode(nonce_hash,'hex') as nonce_hash,
              encode(code_verifier_enc,'hex') as verifier_enc,
              return_to
       from deleted""",
    @[textParam(sha256Hex(state))])
  if row.isNone:
    problem(request, 400, "INVALID_STATE", "flow not found, expired or already used")
    return
  let flow = row.get
  var verifier = ""
  try:
    verifier = decryptWith(application.keyring, application.keyring.active,
      hexBytes(flow.get("verifier_enc")), state)
  except ShareKeyError:
    problem(request, 500, "KEY_ERROR", "cannot decrypt flow")
    return
  var idToken = ""
  try:
    idToken = exchangeCode(application.oidc, code, verifier)
  except CatchableError as error:
    problem(request, 400, "TOKEN_EXCHANGE_FAILED", error.msg)
    return
  var claims: JsonNode
  try:
    claims = verifyIdToken(idToken, jwks(application.oidc),
      application.oidc.issuer, application.oidc.clientId, "",
      epochTime().int64)
  except CatchableError as error:
    problem(request, 401, "INVALID_ID_TOKEN", error.msg)
    return
  if sha256Hex(claims["nonce"].getStr()) != flow.get("nonce_hash"):
    problem(request, 401, "NONCE_MISMATCH", "nonce mismatch")
    return
  let email = claims["email"].getStr()
  let displayName =
    if claims.hasKey("name"): claims["name"].getStr() else: email
  let owner = application.bootstrapOwner.len > 0 and email == application.bootstrapOwner
  let userRow = application.db.queryOne(
    """insert into platform.user
       (google_sub, email_hash, display_name, is_platform_owner)
       values ($1, $2, $3, $4)
       on conflict (google_sub) do update
         set display_name = excluded.display_name,
             is_platform_owner = platform.user.is_platform_owner
                                 or excluded.is_platform_owner
       returning id""",
    @[textParam(claims["sub"].getStr()), textParam(sha256Hex(email)),
      textParam(displayName), boolParam(owner)])
  if userRow.isNone:
    problem(request, 500, "USER_UPSERT_FAILED", "cannot create user")
    return
  let token = createSessionToken(userRow.get.get("id"))
  request.respond(302,
    @[("Location", flow.get("return_to")), ("Set-Cookie", sessionCookie(token))], "")

proc listAuthSessions(request: Request) =
  let user = requireUser(request)
  if user.isNone: return
  let token = cookieValue(request, "majadu_session")
  var items = newJArray()
  for row in listSessions(application.db, user.get.id, token):
    items.add(%*{"id": row.id, "createdAt": row.createdAt,
      "lastSeenAt": row.lastSeenAt, "current": row.current})
  jsonResponse(request, 200, %*{"items": items}, [("Cache-Control", "no-store")])

proc revokeOtherSessions(request: Request) =
  let user = requireUser(request)
  if user.isNone: return
  revokeOthers(application.db, user.get.id, cookieValue(request, "majadu_session"))
  request.respond(204, @[("Cache-Control", "no-store")], "")

proc me(request: Request) =
  let user = requireUser(request)
  if user.isNone: return
  jsonResponse(request, 200, %*{
    "id": user.get.id,
    "displayName": user.get.displayName,
    "platformOwner": user.get.isOwner,
  })

proc logout(request: Request) =
  let token = cookieValue(request, "majadu_session")
  if token.len > 0:
    revoke(application.db, token)
  request.respond(204, @[("Set-Cookie",
    "majadu_session=; Path=/; HttpOnly; SameSite=Lax; Max-Age=0")], "")

proc createCommunity(request: Request) =
  let user = requireUser(request)
  if user.isNone: return
  if not user.get.isOwner:
    problem(request, 403, "FORBIDDEN", "platform owner only")
    return
  let body = bodyJson(request)
  let slug = body["slug"].getStr()
  let name = body["name"].getStr()
  # No hidden default: a community without a timezone inherits the registry L1
  # value, which the platform owner can change without a deploy.
  let timezone =
    if body.hasKey("timezone"): body["timezone"].getStr()
    else: configSnapshot().stringValue(%*{}, keyCommunityDefaultTimezone)
  var row: Option[Row]
  try:
    row = application.db.queryOne(
      """insert into platform.community (slug, name, timezone)
         values ($1, $2, $3) returning id, slug, name, timezone""",
      @[textParam(slug), textParam(name), textParam(timezone)])
  except DbError as error:
    case error.sqlState
    of "23505": problem(request, 409, "SLUG_TAKEN", "community slug already exists")
    of "23514": problem(request, 400, "INVALID_SLUG", "slug or name is invalid")
    else: problem(request, 400, "INVALID_COMMUNITY", "cannot create community")
    return
  if row.isNone:
    problem(request, 500, "CREATE_FAILED", "community was not created")
    return
  let communityId = row.get.get("id")
  discard application.db.execUpdate(
    """insert into community.membership (community_id, user_id, role)
       values ($1, $2, 'admin')""",
    @[textParam(communityId), textParam(user.get.id)])
  audit("community.create", communityId, user.get, "community", communityId,
    %*{"slug": row.get.get("slug"), "name": row.get.get("name")})
  jsonResponse(request, 201, %*{
    "id": communityId,
    "slug": row.get.get("slug"),
    "name": row.get.get("name"),
    "timezone": row.get.get("timezone"),
  })

proc listCommunities(request: Request) =
  let user = requireUser(request)
  if user.isNone: return
  var items = newJArray()
  for row in application.db.query(
    """select c.id, c.slug, c.name, m.role
       from community.membership m
       join platform.community c on c.id = m.community_id
       where m.user_id = $1 order by c.slug""",
    @[textParam(user.get.id)]):
    items.add(%*{"id": row.get("id"), "slug": row.get("slug"),
      "name": row.get("name"), "role": row.get("role")})
  jsonResponse(request, 200, %*{"items": items})

proc createSession(request: Request, ctx: CommunityCtx, user: AuthUser) =
  if not canWrite(ctx, user):
    problem(request, 403, "FORBIDDEN", "host or admin required")
    return
  let body = bodyJson(request)
  let title = if body.hasKey("title"): body["title"].getStr() else: ""
  let date = body["date"].getStr()
  let startTime = if body.hasKey("startTime"): body["startTime"].getStr() else: "00:00"
  let slot = if body.hasKey("slotMinutes"): body["slotMinutes"].getInt() else: 30
  let row = application.db.queryOne(
    """insert into session.sessions
       (community_id, title, session_date, start_time, slot_minutes, status, source)
       values ($1, $2, $3::date, $4::time, $5, 'draft', 'manual')
       returning id, title, session_date::text as session_date, status""",
    @[textParam(ctx.id), textParam(title), textParam(date),
      textParam(startTime), intParam(slot.int64)])
  if row.isNone:
    problem(request, 400, "INVALID_SESSION", "cannot create session")
    return
  audit("session.create", ctx.id, user, "session", row.get.get("id"),
    %*{"title": row.get.get("title"), "date": row.get.get("session_date"),
        "status": row.get.get("status")})
  jsonResponse(request, 201, %*{
    "id": row.get.get("id"),
    "title": row.get.get("title"),
    "date": row.get.get("session_date"),
    "status": row.get.get("status"),
  })

proc listSessions(request: Request, ctx: CommunityCtx) =
  var items = newJArray()
  let limit = configSnapshot().intValue(%*{}, keyApiPageSizeDefault)
  for row in application.db.query(
    """select id, title, session_date::text as session_date, status
       from session.sessions where community_id = $1
       order by session_date desc, updated_at desc limit $2""",
    @[textParam(ctx.id), intParam(limit.int64)]):
    items.add(%*{"id": row.get("id"), "title": row.get("title"),
      "date": row.get("session_date"), "status": row.get("status")})
  jsonResponse(request, 200, %*{"items": items})

proc createShare(request: Request, ctx: CommunityCtx, user: AuthUser,
                 sessionId: string) =
  if not canWrite(ctx, user):
    problem(request, 403, "FORBIDDEN", "host or admin required")
    return
  let session = application.db.queryOne(
    "select id from session.sessions where id = $1 and community_id = $2",
    @[textParam(sessionId), textParam(ctx.id)])
  if session.isNone:
    problem(request, 404, "NOT_FOUND", "session not found")
    return
  let linkId = uuidv7()
  let code = newShareCode()
  let aad = ctx.id & "|" & linkId
  let (keyId, encrypted) = encryptWith(application.keyring, code, aad)
  discard application.db.execUpdate(
    """update session.links set revoked_at = now()
       where session_id = $1 and revoked_at is null""",
    @[textParam(sessionId)])
  discard application.db.execUpdate(
    """insert into session.links
       (id, community_id, session_id, code_hash, code_enc, key_id, created_by)
       values ($1, $2, $3, decode($4,'hex'), decode($5,'hex'), $6, $7)""",
    @[textParam(linkId), textParam(ctx.id), textParam(sessionId),
      textParam(sha256Hex(code)), textParam(bytesHex(encrypted)),
      textParam(keyId), textParam(user.id)])
  audit("share.issue", ctx.id, user, "session", sessionId,
    %*{"sessionId": sessionId})
  jsonResponse(request, 201, %*{"code": code, "sessionId": sessionId})

proc resolveShare(code: string): Option[JsonNode] =
  let row = application.db.queryOne(
    """select l.id as link_id, l.community_id, l.key_id,
              encode(l.code_enc,'hex') as code_enc,
              s.id, s.title, s.session_date::text as session_date, s.status,
              c.slug, c.name
       from session.links l
       join session.sessions s
         on s.community_id = l.community_id and s.id = l.session_id
       join platform.community c on c.id = l.community_id
       where l.code_hash = decode($1,'hex') and l.revoked_at is null""",
    @[textParam(sha256Hex(code))])
  if row.isNone:
    return none(JsonNode)
  let value = row.get
  # Verify the envelope is authentic for this row before serving it.
  try:
    discard decryptWith(application.keyring, value.get("key_id"),
      hexBytes(value.get("code_enc")), value.get("community_id") & "|" & value.get("link_id"))
  except ShareKeyError:
    return none(JsonNode)
  some(%*{
    "session": {"id": value.get("id"), "title": value.get("title"),
                "date": value.get("session_date"), "status": value.get("status")},
    "community": {"slug": value.get("slug"), "name": value.get("name")},
    "games": newJArray(),
  })

proc getShared(request: Request, code: string) =
  let shared = resolveShare(code)
  if shared.isNone:
    problem(request, 404, "NOT_FOUND", "link not found")
    return
  jsonResponse(request, 200, shared.get,
    [("Cache-Control", "no-store"), ("X-Robots-Tag", "noindex")])

proc rankings(request: Request, communityId: string) =
  var items = newJArray()
  let limit = configSnapshot().intValue(%*{}, keyRankBoardLimit)
  for row in application.db.query(
    """select p.id, p.canonical_name, coalesce(ps.rating, 0) as rating
       from player.players p
       left join rating.player_state ps
         on ps.community_id = p.community_id and ps.player_id = p.id
       where p.community_id = $1
       order by rating desc, p.canonical_name limit $2""",
    @[textParam(communityId), intParam(limit.int64)]):
    items.add(%*{"playerId": row.get("id"), "name": row.get("canonical_name"),
      "rating": parseInt(row.get("rating"))})
  jsonResponse(request, 200, %*{"items": items},
    [("Cache-Control", "no-store")])

proc getSharedRankings(request: Request, code: string) =
  let shared = resolveShare(code)
  if shared.isNone:
    problem(request, 404, "NOT_FOUND", "link not found")
    return
  let communityRow = application.db.queryOne(
    """select l.community_id from session.links l
       where l.code_hash = decode($1,'hex') and l.revoked_at is null""",
    @[textParam(sha256Hex(code))])
  if communityRow.isNone:
    problem(request, 404, "NOT_FOUND", "link not found")
    return
  rankings(request, communityRow.get.get("community_id"))

proc route(request: Request) =
  try:
    let path = request.path
    let verb = request.httpMethod
    if path == "/healthz":
      request.respond(200, @[("Content-Type", "application/json")], """{"status":"ok"}""")
      return
    if path == "/readyz":
      discard application.db.queryOne("select 1 as ok")
      request.respond(200, @[("Content-Type", "application/json")], """{"status":"ok"}""")
      return
    case path
    of "/auth/start":
      if verb == "POST": startAuth(request) else: problem(request, 405, "METHOD", "")
      return
    of "/auth/callback":
      if verb == "GET": finishAuth(request) else: problem(request, 405, "METHOD", "")
      return
    of "/auth/logout":
      if verb == "POST": logout(request) else: problem(request, 405, "METHOD", "")
      return
    of "/auth/me":
      if verb == "GET": me(request) else: problem(request, 405, "METHOD", "")
      return
    of "/auth/sessions":
      if verb == "GET": listAuthSessions(request)
      elif verb == "DELETE": revokeOtherSessions(request)
      else: problem(request, 405, "METHOD", "")
      return
    of "/communities":
      if verb == "POST": createCommunity(request)
      elif verb == "GET": listCommunities(request)
      else: problem(request, 405, "METHOD", "")
      return
    else: discard

    let parts = path.split('/')
    # /c/{slug}/sessions[/{id}[/share]]
    if parts.len >= 4 and parts[1] == "c" and parts[3] == "sessions":
      let slug = parts[2]
      let user = currentUser(request)
      if user.isNone:
        problem(request, 401, "UNAUTHENTICATED", "login required")
        return
      let ctx = resolveCommunity(user.get, slug)
      if ctx.isNone:
        problem(request, 404, "NOT_FOUND", "community not found")
        return
      if parts.len == 4 and verb == "GET":
        listSessions(request, ctx.get)
        return
      if parts.len == 4 and verb == "POST":
        createSession(request, ctx.get, user.get)
        return
      if parts.len == 5 and verb == "GET":
        let row = application.db.queryOne(
          """select id, title, session_date::text as session_date, status
             from session.sessions where id = $1 and community_id = $2""",
          @[textParam(parts[4]), textParam(ctx.get.id)])
        if row.isNone:
          problem(request, 404, "NOT_FOUND", "session not found")
          return
        jsonResponse(request, 200, %*{"id": row.get.get("id"),
          "title": row.get.get("title"), "date": row.get.get("session_date"),
          "status": row.get.get("status")})
        return
      if parts.len == 6 and parts[5] == "share" and verb == "POST":
        createShare(request, ctx.get, user.get, parts[4])
        return
    # /c/{slug}/rankings
    if parts.len == 4 and parts[1] == "c" and parts[3] == "rankings":
      let user = currentUser(request)
      if user.isNone:
        problem(request, 401, "UNAUTHENTICATED", "login required")
        return
      let ctx = resolveCommunity(user.get, parts[2])
      if ctx.isNone:
        problem(request, 404, "NOT_FOUND", "community not found")
        return
      rankings(request, ctx.get.id)
      return
    # /s/{code} and /s/{code}/rankings
    if parts.len >= 3 and parts[1] == "s":
      let code = parts[2]
      if parts.len == 3:
        getShared(request, code)
        return
      if parts.len == 4 and parts[3] == "rankings":
        getSharedRankings(request, code)
        return
    problem(request, 404, "NOT_FOUND", "route not found")
  except CatchableError as error:
    stderr.writeLine "app error: " & error.msg
    problem(request, 500, "INTERNAL", "internal error")

proc newApp*(db: Db, oidc: OidcConfig, keyring: Keyring,
             config: ConfigCache): App =
  App(db: db, oidc: oidc, keyring: keyring, config: config,
      cookieSecure: getEnv("MAJADU_COOKIE_SECURE") == "1",
      bootstrapOwner: getEnv("MAJADU_BOOTSTRAP_OWNER_EMAIL"))

proc install*(app: App) =
  application = app

proc handler*(): RequestHandler =
  ## The App lives in a process-wide ref shared by every worker thread. Mummy
  ## requires a gcsafe handler; the cast is the single audited boundary, because
  ## `application` is assigned once at boot and never mutated afterwards.
  result = proc(request: Request) {.gcsafe.} =
    {.cast(gcsafe).}:
      route(request)
