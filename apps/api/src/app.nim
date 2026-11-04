import std/[base64, json, options, os, strutils, sysrand, times, uri]
import mummy
import auth_middleware
import community_context
import community/domain/community as communityDomain
import community/infrastructure/community_store
import community/infrastructure/invite as inviteStore
import community/infrastructure/join_request as joinRequestStore
import community/infrastructure/membership as membershipStore
import config as edgeConfig
import config_routes
import live
import metrics
import ratelimit
import security_headers
import db/db
import sha256
import uuidv7
import share/crypto
import share/store as shareStore
import session/write as sessionWrite
import ws_ticket as wsTicket
import platform/idempotency
import account/domain/audit
import account/domain/roles
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
    limiter*: Limiter
    hub*: LiveHub
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

proc send(request: Request, status: int,
          headers: openArray[(string, string)], body: string) =
  ## Single response path: every response carries the security headers, so a new
  ## route cannot silently ship without CSP or nosniff.
  var merged = @headers
  for pair in securityHeaders(application.cookieSecure):
    merged.add(pair)
  request.respond(status, merged, body)

proc send(request: Request, status: int, body: string) =
  send(request, status, @[("Content-Type", "application/json")], body)

proc jsonResponse(request: Request, status: int, body: JsonNode,
                  extra: openArray[(string, string)] = []) =
  var headers = @[("Content-Type", "application/json")]
  for pair in extra:
    headers.add(pair)
  send(request, status, headers, $body)

proc problem(request: Request, status: int, code, detail: string) =
  send(request, status, $ %*{"status": status, "code": code, "detail": detail})

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
  send(request, 204, @[("Set-Cookie", cookie)], "")

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

proc actorOf(user: AuthUser, token: string): Actor =
  Actor(userId: user.id, isPlatformOwner: user.isOwner, sessionToken: token)

proc readAccess(): Access =
  ## Any membership role can read; the community context already proved
  ## membership, and roles decide writes only.
  Access(isSession: true)

proc writeAccess(): Access =
  Access(isSession: true, roles: @[rHost, rAdmin])

proc decide(user: AuthUser, token, slug: string,
            access: Access): (Gate, Option[CommunityContext]) =
  ## Membership is resolved before the gate so a foreign slug is a 404, not a
  ## 403 that confirms the community exists.
  let ctx = loadCommunity(application.db, user.id, slug)
  (gate(access, some(actorOf(user, token)), ctx), ctx)

proc respondGate(request: Request, decision: Gate) =
  problem(request, statusFor(decision), codeFor(decision), codeFor(decision))

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
  # Invitations bound to this address (including the first-admin invite created
  # with the community) are honoured at login.
  discard inviteStore.acceptPendingForEmail(application.db,
    userRow.get.get("id"), sha256Hex(email))
  let token = createSessionToken(userRow.get.get("id"))
  send(request, 302,
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
  application.hub.revokePrincipal(user.get.id)
  send(request, 204, @[("Cache-Control", "no-store")], "")

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
  let user = currentUser(request)
  if token.len > 0:
    revoke(application.db, token)
  # Sockets and every ticket of the principal close with the session.
  if user.isSome:
    application.hub.revokePrincipal(user.get.id)
  send(request, 204, @[("Set-Cookie",
    "majadu_session=; Path=/; HttpOnly; SameSite=Lax; Max-Age=0")], "")

proc ownerOnly(request: Request): Option[AuthUser] =
  ## Platform-owner management routes: 401 before 403, never a community check.
  result = requireUser(request)
  if result.isNone:
    return
  if not result.get.isOwner:
    problem(request, 403, "FORBIDDEN", "platform owner only")
    return none(AuthUser)

proc adminGate(request: Request,
               slug: string): Option[(AuthUser, CommunityContext)] =
  ## Admin-only community management. A foreign slug stays a 404, so the role
  ## check never confirms that a community exists.
  let user = requireUser(request)
  if user.isNone:
    return none((AuthUser, CommunityContext))
  let (decision, ctx) = decide(user.get, cookieValue(request, "majadu_session"),
    slug, Access(isSession: true, roles: @[rAdmin]))
  if decision != gAllowed:
    respondGate(request, decision)
    return none((AuthUser, CommunityContext))
  some((user.get, ctx.get))

proc createCommunity(request: Request) =
  let user = ownerOnly(request)
  if user.isNone:
    return
  var body: JsonNode
  try:
    body = bodyJson(request)
  except ValueError:
    problem(request, 400, "INVALID_BODY", "body must be JSON")
    return
  let slug = if body.hasKey("slug") and body["slug"].kind == JString:
    body["slug"].getStr() else: ""
  let name = if body.hasKey("name") and body["name"].kind == JString:
    body["name"].getStr() else: ""
  let adminEmail = if body.hasKey("adminEmail") and body["adminEmail"].kind == JString:
    body["adminEmail"].getStr() else: ""
  let timezone =
    if body.hasKey("timezone") and body["timezone"].kind == JString:
      some(body["timezone"].getStr())
    else:
      none(string)
  let check = communityDomain.checkCreate(slug, name, adminEmail,
    configSnapshot().stringValue(%*{}, keyCommunityDefaultTimezone), timezone)
  if check.problems.len > 0:
    problem(request, 400, "INVALID_COMMUNITY", $check.problems[0])
    return
  let created = communityStore.create(application.db, check.slug, name.strip(),
    adminEmail, check.timezone, user.get.id)
  case created.status
  of csSlugTaken:
    problem(request, 409, "SLUG_TAKEN", "community slug already exists")
  of csOk:
    audit("community.create", created.communityId, user.get, "community",
      created.communityId, %*{"slug": check.slug})
    jsonResponse(request, 201, %*{
      "id": created.communityId,
      "slug": check.slug,
      "name": name.strip(),
      "timezone": check.timezone,
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

proc createSession(request: Request, ctx: CommunityContext, user: AuthUser) =
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
    @[textParam(ctx.communityId), textParam(title), textParam(date),
      textParam(startTime), intParam(slot.int64)])
  if row.isNone:
    problem(request, 400, "INVALID_SESSION", "cannot create session")
    return
  audit("session.create", ctx.communityId, user, "session", row.get.get("id"),
    %*{"title": row.get.get("title"), "date": row.get.get("session_date"),
        "status": row.get.get("status")})
  jsonResponse(request, 201, %*{
    "id": row.get.get("id"),
    "title": row.get.get("title"),
    "date": row.get.get("session_date"),
    "status": row.get.get("status"),
  })

proc listSessions(request: Request, ctx: CommunityContext) =
  var items = newJArray()
  let limit = configSnapshot().intValue(%*{}, keyApiPageSizeDefault)
  for row in application.db.query(
    """select id, title, session_date::text as session_date, status, version
       from session.sessions where community_id = $1
       order by session_date desc, updated_at desc limit $2""",
    @[textParam(ctx.communityId), intParam(limit.int64)]):
    items.add(%*{"id": row.get("id"), "title": row.get("title"),
      "date": row.get("session_date"), "status": row.get("status"),
      "version": parseInt(row.get("version"))})
  jsonResponse(request, 200, %*{"items": items})

proc createShare(request: Request, ctx: CommunityContext, user: AuthUser,
                 sessionId: string) =
  let session = application.db.queryOne(
    "select id from session.sessions where id = $1 and community_id = $2",
    @[textParam(sessionId), textParam(ctx.communityId)])
  if session.isNone:
    problem(request, 404, "NOT_FOUND", "session not found")
    return
  # Issuing a link revokes the previous one in the same transaction, so its
  # watchers and their tickets go too.
  let previous = application.db.queryOne(
    """select id from session.links
       where community_id = $1::uuid and session_id = $2::uuid
         and revoked_at is null""",
    @[textParam(ctx.communityId), textParam(sessionId)])
  let code = shareStore.issue(application.db, application.keyring,
    ctx.communityId, sessionId, user.id)
  if previous.isSome:
    application.hub.revokeShare(previous.get.get("id"))
  audit("share.issue", ctx.communityId, user, "session", sessionId,
    %*{"sessionId": sessionId})
  jsonResponse(request, 201, %*{"code": code, "sessionId": sessionId})

proc issueSessionTicket(request: Request, ctx: CommunityContext, user: AuthUser,
                        sessionId: string) =
  ## Read access is enough: any member may watch. The ticket is bound to the
  ## session row, so a foreign-community id is a 404 before anything is issued.
  let session = application.db.queryOne(
    "select id from session.sessions where id = $1 and community_id = $2",
    @[textParam(sessionId), textParam(ctx.communityId)])
  if session.isNone:
    problem(request, 404, "NOT_FOUND", "session not found")
    return
  let ttl = configSnapshot().intValue(%*{}, keyWsTicketTtlSeconds)
  let ticket = wsTicket.issueSession(application.db, user.id, sessionId, ttl)
  jsonResponse(request, 200, %*{"ticket": ticket, "expiresIn": ttl},
    [("Cache-Control", "no-store")])

proc issueShareTicket(request: Request, code: string) =
  ## Anonymous path: the share limiter has already run in `route`, before this
  ## insert. Only a `share` channel ticket is ever minted here.
  let found = shareStore.resolve(application.db, application.keyring, code)
  if found.isNone:
    problem(request, 404, "NOT_FOUND", "link not found")
    return
  let ttl = configSnapshot().intValue(%*{}, keyWsTicketTtlSeconds)
  let ticket = wsTicket.issueShare(application.db, found.get.linkId, ttl)
  jsonResponse(request, 200, %*{"ticket": ticket, "expiresIn": ttl},
    [("Cache-Control", "no-store"), ("X-Robots-Tag", "noindex")])

proc ifMatch(request: Request): Option[int] =
  ## OCC precondition. Missing is 428, not 400: the client must opt in.
  let raw = request.headers["If-Match"].strip(chars = {'"', ' ', 'W', '/'})
  if raw.len == 0:
    return none(int)
  try:
    some(parseInt(raw))
  except ValueError:
    none(int)

proc requireIfMatch(request: Request): Option[int] =
  result = ifMatch(request)
  if result.isNone:
    problem(request, 428, "PRECONDITION_REQUIRED", "If-Match is required")

proc idempotentWrite(request: Request, userId, communityId, key: string,
                     body: string): Option[JsonNode] =
  ## Returns the stored response for a replay, a 409 body for a conflict, and
  ## none when the caller must do the work.
  if key.len == 0:
    return none(JsonNode)
  let scoped = scopedKey(communityId, key)
  let entry = claim(application.db, userId, scoped, bodyHash(body))
  case entry.status
  of idempotencyNew:
    none(JsonNode)
  of idempotencyReplay:
    jsonResponse(request, entry.statusCode, entry.response)
    some(entry.response)
  of idempotencyConflict:
    let body = %*{"status": 409, "code": "IDEMPOTENCY_CONFLICT",
                  "detail": "this key was used with a different body"}
    problem(request, 409, "IDEMPOTENCY_CONFLICT", "this key was used with a different body")
    some(body)

proc patchSession(request: Request, ctx: CommunityContext, user: AuthUser,
                  sessionId: string) =
  let version = requireIfMatch(request)
  if version.isNone: return
  let key = request.headers["Idempotency-Key"]
  if idempotentWrite(request, user.id, ctx.communityId, key, request.body).isSome:
    return
  var patchBody: SessionPatch
  try:
    patchBody = parsePatch(bodyJson(request))
  except ValueError as error:
    problem(request, 400, "INVALID_PATCH", error.msg)
    return
  let result = sessionWrite.patch(application.db, ctx.communityId, sessionId,
    version.get, patchBody)
  case result.status
  of wsOk:
    audit("session.patch", ctx.communityId, user, "session", sessionId,
      result.record)
    if key.len > 0:
      complete(application.db, user.id, scopedKey(ctx.communityId, key), 200,
        result.record)
    application.hub.sessionChanged(sessionId, result.record["version"].getInt())
    jsonResponse(request, 200, result.record,
      [("ETag", "\"" & $result.record["version"].getInt() & "\""),
       ("Cache-Control", "no-store")])
  of wsStale:
    problem(request, 412, "STALE_VERSION", "session changed since If-Match")
  of wsNotFound:
    problem(request, 404, "NOT_FOUND", "session not found")
  of wsInvalid:
    problem(request, 400, "INVALID_PATCH", "cannot apply patch")

proc setSessionLock(request: Request, ctx: CommunityContext, user: AuthUser,
                    sessionId: string, locked: bool) =
  let version = requireIfMatch(request)
  if version.isNone: return
  let result = sessionWrite.setLock(application.db, ctx.communityId, sessionId,
    user.id, version.get, locked)
  case result.status
  of wsOk:
    audit(if locked: "session.lock" else: "session.unlock", ctx.communityId, user,
      "session", sessionId, result.record)
    jsonResponse(request, 200, result.record,
      [("ETag", "\"" & $result.record["version"].getInt() & "\""),
       ("Cache-Control", "no-store")])
  of wsStale:
    problem(request, 412, "STALE_VERSION", "session changed since If-Match")
  of wsNotFound:
    problem(request, 404, "NOT_FOUND", "session not found")
  of wsInvalid:
    problem(request, 400, "INVALID_PATCH", "cannot lock session")
  if result.status == wsOk:
    application.hub.sessionChanged(sessionId, result.record["version"].getInt())

proc getCommunitySettings(request: Request, ctx: CommunityContext) =
  let settings = currentSettings(application.db, ctx.communityId)
  let snapshot = configSnapshot()
  jsonResponse(request, 200, %*{
    "values": settings,
    "effective": effectiveConfig(snapshot, settings),
  }, [("Cache-Control", "no-store")])

proc patchCommunitySettings(request: Request, ctx: CommunityContext,
                            user: AuthUser) =
  var body: JsonNode
  try:
    body = bodyJson(request)
  except ValueError:
    problem(request, 400, "INVALID_BODY", "settings patch must be JSON")
    return
  let result = applyPatch(application.db, configSnapshot(), ctx.communityId,
    user.id, body)
  case result.outcome
  of soOk:
    jsonResponse(request, 200,
      %*{"values": currentSettings(application.db, ctx.communityId)},
      [("Cache-Control", "no-store")])
  of soUnknownKey:
    problem(request, 400, "UNKNOWN_CONFIG_KEY", result.detail & ": " & result.key)
  of soOutOfCeiling:
    problem(request, 400, "OVERRIDE_TOO_HIGH", result.detail & ": " & result.key)
  of soInvalidType:
    problem(request, 400, "INVALID_CONFIG_VALUE", result.detail & ": " & result.key)

proc directory(request: Request) =
  ## Public listing. Outsiders only see communities that opted in; a member also
  ## sees their own. Entries carry the slug and the name, nothing else.
  let user = currentUser(request)
  let snapshot = configSnapshot()
  let items = communityStore.directory(application.db,
    (if user.isSome: some(user.get.id) else: none(string)),
    snapshot.boolValue(%*{}, keyCommunityDirectoryEnabled),
    $keyCommunityDirectoryEnabled)
  jsonResponse(request, 200, %*{"items": items}, [("Cache-Control", "no-store")])

proc createInvite(request: Request, ctx: CommunityContext, user: AuthUser) =
  var body: JsonNode
  try:
    body = bodyJson(request)
  except ValueError:
    problem(request, 400, "INVALID_BODY", "body must be JSON")
    return
  let email = if body.hasKey("email") and body["email"].kind == JString:
    body["email"].getStr() else: ""
  if not communityDomain.validEmail(email):
    problem(request, 400, "INVALID_EMAIL", "a valid email is required")
    return
  let role = if body.hasKey("role") and body["role"].kind == JString:
    body["role"].getStr() else: "member"
  var parsed: Role
  try:
    parsed = parseRole(role)
  except ValueError:
    problem(request, 400, "INVALID_ROLE", "role must be member, host or admin")
    return
  let ttl = configSnapshot().intValue(%*{}, keyCommunityInviteTtlDays)
  let token = inviteStore.create(application.db, ctx.communityId,
    sha256Hex(email.strip().toLowerAscii()), $parsed, user.id, ttl)
  audit("community.invite", ctx.communityId, user, "community", ctx.communityId,
    %*{"role": $parsed})
  jsonResponse(request, 201, %*{"token": token, "expiresInDays": ttl, "role": $parsed},
    [("Cache-Control", "no-store")])

proc acceptInvite(request: Request, token: string) =
  let user = requireUser(request)
  if user.isNone:
    return
  let result = inviteStore.accept(application.db, token, user.get.id,
    user.get.emailHash)
  case result.outcome
  of aoOk:
    audit("community.join", result.communityId, user.get, "community",
      result.communityId, %*{"role": result.role})
    jsonResponse(request, 201, %*{"communityId": result.communityId,
      "role": result.role})
  of aoNotFound:
    problem(request, 404, "INVITE_NOT_FOUND", "invitation not found")
  of aoUsed:
    problem(request, 410, "INVITE_USED", "invitation was already used")
  of aoExpired:
    problem(request, 410, "INVITE_EXPIRED", "invitation has expired")
  of aoEmailMismatch:
    problem(request, 403, "INVITE_EMAIL_MISMATCH",
      "invitation belongs to another address")

proc requestJoin(request: Request, slug: string) =
  ## Anti-enumeration: an unknown slug, a community that is not accepting and an
  ## already-pending request all return the same 202 body.
  const accepted = """{"status":"accepted"}"""
  let user = currentUser(request)
  let row = if user.isSome:
    application.db.queryOne(
      """select c.id,
                coalesce((s.values ->> $2)::boolean, $3) as enabled
         from platform.community c
         left join community.settings s on s.community_id = c.id
         where c.slug = $1""",
      @[textParam(slug),
        textParam($keyCommunityJoinRequestsEnabled),
        boolParam(configSnapshot().boolValue(%*{}, keyCommunityJoinRequestsEnabled))])
    else:
      none(Row)
  if row.isSome and row.get.get("enabled") == "t":
    discard joinRequestStore.request(application.db, row.get.get("id"), user.get.id)
  send(request, 202, @[("Content-Type", "application/json"),
    ("Cache-Control", "no-store")], accepted)

proc listJoinRequests(request: Request, ctx: CommunityContext) =
  var items = newJArray()
  for entry in joinRequestStore.listPending(application.db, ctx.communityId):
    items.add(%*{"id": entry.id, "userId": entry.userId,
      "displayName": entry.displayName, "createdAt": entry.createdAt})
  jsonResponse(request, 200, %*{"items": items}, [("Cache-Control", "no-store")])

proc decideJoinRequest(request: Request, ctx: CommunityContext, user: AuthUser,
                       requestId: string) =
  var body: JsonNode
  try:
    body = bodyJson(request)
  except ValueError:
    problem(request, 400, "INVALID_BODY", "body must be JSON")
    return
  let decision = if body.hasKey("decision") and body["decision"].kind == JString:
    body["decision"].getStr() else: ""
  if decision notin ["approve", "reject"]:
    problem(request, 400, "INVALID_DECISION", "decision must be approve or reject")
    return
  let role = if body.hasKey("role") and body["role"].kind == JString:
    body["role"].getStr() else: "member"
  try:
    discard parseRole(role)
  except ValueError:
    problem(request, 400, "INVALID_ROLE", "role must be member, host or admin")
    return
  let approve = decision == "approve"
  if not joinRequestStore.decide(application.db, ctx.communityId, requestId,
      user.id, role, approve):
    problem(request, 404, "NOT_FOUND", "pending request not found")
    return
  audit(if approve: "community.join.approved" else: "community.join.rejected",
    ctx.communityId, user, "join_request", requestId, %*{"role": role})
  jsonResponse(request, 200, %*{"status": if approve: "approved" else: "rejected"})

proc listMembers(request: Request, ctx: CommunityContext) =
  var items = newJArray()
  for member in membershipStore.list(application.db, ctx.communityId):
    items.add(%*{"userId": member.userId, "displayName": member.displayName,
      "role": member.role, "joinedAt": member.joinedAt})
  jsonResponse(request, 200, %*{"items": items}, [("Cache-Control", "no-store")])

proc soleAdmin(db: Db, communityId, userId: string): bool =
  ## Removing or demoting the only admin would leave the community unmanageable.
  let row = db.queryOne(
    """select
         (select count(*) from community.membership
          where community_id = $1::uuid and role = 'admin') as admins,
         (select role from community.membership
          where community_id = $1::uuid and user_id = $2::uuid) as current""",
    @[textParam(communityId), textParam(userId)])
  row.isSome and row.get.get("admins") == "1" and row.get.get("current") == "admin"

proc patchMemberRole(request: Request, ctx: CommunityContext, user: AuthUser,
                     targetId: string) =
  var body: JsonNode
  try:
    body = bodyJson(request)
  except ValueError:
    problem(request, 400, "INVALID_BODY", "body must be JSON")
    return
  let role = if body.hasKey("role") and body["role"].kind == JString:
    body["role"].getStr() else: ""
  try:
    discard parseRole(role)
  except ValueError:
    problem(request, 400, "INVALID_ROLE", "role must be member, host or admin")
    return
  if role != "admin" and soleAdmin(application.db, ctx.communityId, targetId):
    problem(request, 409, "LAST_ADMIN", "promote another admin first")
    return
  if not membershipStore.setRole(application.db, ctx.communityId, targetId, role):
    problem(request, 404, "NOT_FOUND", "member not found")
    return
  audit("community.member.role", ctx.communityId, user, "user", targetId,
    %*{"role": role})
  jsonResponse(request, 200, %*{"userId": targetId, "role": role})

proc removeMember(request: Request, ctx: CommunityContext, user: AuthUser,
                  targetId: string) =
  if soleAdmin(application.db, ctx.communityId, targetId):
    problem(request, 409, "LAST_ADMIN", "promote another admin first")
    return
  if not membershipStore.remove(application.db, ctx.communityId, targetId):
    problem(request, 404, "NOT_FOUND", "member not found")
    return
  # A removed member loses the sockets and tickets of that principal.
  application.hub.revokePrincipal(targetId)
  audit("community.member.remove", ctx.communityId, user, "user", targetId)
  send(request, 204, @[("Cache-Control", "no-store")], "")

proc communityConfig(request: Request, ctx: CommunityContext) =
  ## Effective registry values for this community, with the source of each one.
  jsonResponse(request, 200,
    %*{"effective": effectiveConfig(configSnapshot(),
      currentSettings(application.db, ctx.communityId))},
    [("Cache-Control", "no-store")])

proc getShareLink(request: Request, ctx: CommunityContext, user: AuthUser,
                  sessionId: string) =
  ## Re-display of the live code: host/admin only, and every read is audited.
  let code = shareStore.currentCode(application.db, application.keyring,
    ctx.communityId, sessionId)
  if code.isNone:
    problem(request, 404, "NOT_FOUND", "no live share link")
    return
  audit("share.redisplay", ctx.communityId, user, "session", sessionId,
    %*{"sessionId": sessionId})
  jsonResponse(request, 200, %*{"code": code.get, "sessionId": sessionId},
    [("Cache-Control", "no-store")])

proc resolveShare(code: string): Option[JsonNode] =
  let found = shareStore.resolve(application.db, application.keyring, code)
  if found.isNone:
    return none(JsonNode)
  let value = found.get
  var games = newJArray()
  for row in application.db.query(
    """select id, round_no, court_no, score_a, score_b, status
       from session.games
       where community_id = $1::uuid and session_id = $2::uuid
       order by round_no, court_no""",
    @[textParam(value.communityId), textParam(value.sessionId)]):
    games.add(%*{
      "id": row.get("id"),
      "round": parseInt(row.get("round_no")),
      "court": parseInt(row.get("court_no")),
      "scoreA": if row["score_a"].isNone: newJNull() else: %parseInt(row.get("score_a")),
      "scoreB": if row["score_b"].isNone: newJNull() else: %parseInt(row.get("score_b")),
      "status": row.get("status"),
    })
  some(%*{
    "session": {"id": value.sessionId, "title": value.title,
                "date": value.sessionDate, "status": value.status},
    "community": {"slug": value.slug, "name": value.communityName},
    "games": games,
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
  let found = shareStore.resolve(application.db, application.keyring, code)
  if found.isNone:
    problem(request, 404, "NOT_FOUND", "link not found")
    return
  rankings(request, found.get.communityId)

proc upgradeSocket(request: Request, snapshot: Snapshot, kind, channelId,
                   clientAddress: string) =
  ## Reached only after the origin check in `handleWebSocket`. The ticket is a
  ## query parameter, so it is read here and never echoed: this process keeps no
  ## access log and no log line below repeats the request path.
  let ticket = request.queryParams["ticket"]
  let consumed = wsTicket.consume(application.db, ticket, kind, channelId)
  if consumed.isNone:
    problem(request, 401, "UNAUTHENTICATED",
      "ticket is invalid, expired or already used")
    return
  var socket: WebSocket
  try:
    socket = request.upgradeToWebSocket()
  except MummyError:
    problem(request, 400, "UPGRADE_REQUIRED", "websocket upgrade required")
    return
  let caps = WatcherCaps(
    perSession: snapshot.intValue(%*{}, keyWsMaxWatchersPerSession),
    perIp: snapshot.intValue(%*{}, keyWsMaxWatchersPerIp),
    process: snapshot.intValue(%*{}, keyWsMaxWatchersProcess))
  let userId =
    if consumed.get.userId.isSome: consumed.get.userId.get else: ""
  if not application.hub.admit(socket, kind & ":" & channelId, userId,
      clientAddress, caps):
    socket.send(fullFrame)
    socket.close()
    return
  socket.send(readyFrame)

proc handleWebSocket(request: Request, snapshot: Snapshot, parts: seq[string]) =
  if request.httpMethod != "GET":
    problem(request, 405, "METHOD", "")
    return
  # Origin is checked before anything else on both channels, so a browser
  # handshake either comes from `security.allowed_origins` or never upgrades.
  # Handshakes without Origin are not browser-driven and authenticate by ticket
  # alone, matching the rule `csrfCheck` already applies to cookie requests.
  let origin = request.headers["Origin"]
  if origin.len > 0 and not originAllowed(snapshot, origin):
    problem(request, 403, "ORIGIN_FORBIDDEN", "origin is not allowed")
    return
  let address = clientIp(request, trustedProxies())
  if parts.len == 6 and parts[2] == "c" and parts[4] == "sessions":
    # The ticket names the session, but the URL also names a community: refuse
    # a handshake that combines a valid ticket with someone else's slug.
    let session = application.db.queryOne(
      """select 1 as ok from session.sessions s
         join platform.community c on c.id = s.community_id
         where s.id = $1::uuid and c.slug = $2""",
      @[textParam(parts[5]), textParam(parts[3])])
    if session.isNone:
      problem(request, 404, "NOT_FOUND", "session not found")
      return
    upgradeSocket(request, snapshot, wsTicket.kindSession, parts[5], address)
    return
  if parts.len == 4 and parts[2] == "share":
    let found = shareStore.resolve(application.db, application.keyring, parts[3])
    if found.isNone:
      problem(request, 401, "UNAUTHENTICATED",
        "ticket is invalid, expired or already used")
      return
    upgradeSocket(request, snapshot, wsTicket.kindShare, found.get.linkId, address)
    return
  problem(request, 404, "NOT_FOUND", "route not found")

proc route(request: Request) =
  try:
    let path = request.path
    let verb = request.httpMethod
    let snapshot = configSnapshot()
    if request.body.len > 0 and bodyTooLarge(request, snapshot):
      problem(request, 413, "BODY_TOO_LARGE", "request body exceeds the limit")
      return
    if csrfCheck(request, snapshot) == csrfRejected:
      problem(request, 403, "CSRF_REJECTED", "origin is not allowed")
      return
    let client = clientIp(request, trustedProxies())
    let routeLabel = templateRoute(path)
    let budget = application.limiter.hit(routeLabel & "|" & client,
      snapshot.intValue(%*{}, keySecurityRateLimitPerMinute), epochTime())
    if not budget.allowed:
      send(request, 429,
        @[("Content-Type", "application/json"), ("Cache-Control", "no-store"),
          ("Retry-After", $budget.retryAfter)],
        $ %*{"status": 429, "code": "RATE_LIMITED", "retryAfter": budget.retryAfter})
      return
    # Share links get their own ceiling per code, so a scraped code cannot be
    # replayed from a pool of addresses.
    if path.startsWith("/s/"):
      let parts = path.split('/')
      if parts.len >= 3:
        let scrape = application.limiter.hit("share|" & parts[2],
          snapshot.intValue(%*{}, keySecurityShareScrapeLimit), epochTime())
        if not scrape.allowed:
          send(request, 429,
            @[("Content-Type", "application/json"), ("Cache-Control", "no-store"),
              ("Retry-After", $scrape.retryAfter)],
            $ %*{"status": 429, "code": "RATE_LIMITED", "retryAfter": scrape.retryAfter})
          return
    if path == "/healthz":
      send(request, 200, """{"status":"ok"}""")
      return
    if path == "/readyz":
      discard application.db.queryOne("select 1 as ok")
      send(request, 200, """{"status":"ok"}""")
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
    of "/directory":
      if verb == "GET": directory(request)
      else: problem(request, 405, "METHOD", "")
      return
    else: discard

    let parts = path.split('/')
    # /ws/c/{slug}/sessions/{id} and /ws/share/{code}
    if parts.len >= 3 and parts[1] == "ws":
      handleWebSocket(request, snapshot, parts)
      return
    # /c/{slug}/sessions[/{id}[/share]]
    if parts.len >= 4 and parts[1] == "c" and parts[3] == "sessions":
      let slug = parts[2]
      let user = currentUser(request)
      if user.isNone:
        problem(request, 401, "UNAUTHENTICATED", "login required")
        return
      let token = cookieValue(request, "majadu_session")
      let access =
        if parts.len == 6 and parts[5] == "ws-ticket": readAccess()
        elif parts.len >= 6: writeAccess()
        elif verb == "GET": readAccess()
        else: writeAccess()
      let (decision, ctx) = decide(user.get, token, slug, access)
      if decision != gAllowed:
        respondGate(request, decision)
        return
      if parts.len == 4 and verb == "GET":
        listSessions(request, ctx.get)
        return
      if parts.len == 4 and verb == "POST":
        createSession(request, ctx.get, user.get)
        return
      if parts.len == 5 and verb == "PATCH":
        patchSession(request, ctx.get, user.get, parts[4])
        return
      if parts.len == 6 and parts[5] in ["lock", "unlock"] and verb == "POST":
        setSessionLock(request, ctx.get, user.get, parts[4], parts[5] == "lock")
        return
      if parts.len == 5 and verb == "GET":
        let row = application.db.queryOne(
          """select id, title, session_date::text as session_date, status, version
             from session.sessions where id = $1 and community_id = $2""",
          @[textParam(parts[4]), textParam(ctx.get.communityId)])
        if row.isNone:
          problem(request, 404, "NOT_FOUND", "session not found")
          return
        jsonResponse(request, 200, %*{"id": row.get.get("id"),
          "title": row.get.get("title"), "date": row.get.get("session_date"),
          "status": row.get.get("status"),
          "version": parseInt(row.get.get("version"))},
          [("ETag", "\"" & row.get.get("version") & "\""),
           ("Cache-Control", "no-store")])
        return
      if parts.len == 6 and parts[5] == "share":
        if verb == "POST":
          createShare(request, ctx.get, user.get, parts[4])
          return
        if verb == "GET":
          getShareLink(request, ctx.get, user.get, parts[4])
          return
      if parts.len == 6 and parts[5] == "ws-ticket" and verb == "POST":
        issueSessionTicket(request, ctx.get, user.get, parts[4])
        return
    # /invites/{token}/accept
    if parts.len == 4 and parts[1] == "invites" and parts[3] == "accept":
      if verb == "POST": acceptInvite(request, parts[2])
      else: problem(request, 405, "METHOD", "")
      return
    # Anonymous join request: always the same 202, whatever the reason.
    if parts.len == 4 and parts[1] == "c" and parts[3] == "join-requests" and
       verb == "POST":
      requestJoin(request, parts[2])
      return
    # /c/{slug}/members[/{userId}], /c/{slug}/join-requests[/{id}],
    # /c/{slug}/invites, /c/{slug}/config
    if parts.len >= 4 and parts[1] == "c" and
       parts[3] in ["members", "join-requests", "invites", "config"]:
      if parts[3] == "members" and parts.len == 4 and verb == "GET":
        let user = requireUser(request)
        if user.isNone: return
        let (decision, ctx) = decide(user.get,
          cookieValue(request, "majadu_session"), parts[2], readAccess())
        if decision != gAllowed:
          respondGate(request, decision)
          return
        listMembers(request, ctx.get)
        return
      let admin = adminGate(request, parts[2])
      if admin.isNone: return
      let (user, ctx) = admin.get
      if parts[3] == "members" and parts.len == 5:
        if verb == "PATCH": patchMemberRole(request, ctx, user, parts[4])
        elif verb == "DELETE": removeMember(request, ctx, user, parts[4])
        else: problem(request, 405, "METHOD", "")
        return
      if parts[3] == "join-requests" and parts.len == 4 and verb == "GET":
        listJoinRequests(request, ctx)
        return
      if parts[3] == "join-requests" and parts.len == 5 and verb == "PATCH":
        decideJoinRequest(request, ctx, user, parts[4])
        return
      if parts[3] == "invites" and parts.len == 4 and verb == "POST":
        createInvite(request, ctx, user)
        return
      if parts[3] == "config" and parts.len == 4 and verb == "GET":
        communityConfig(request, ctx)
        return
      problem(request, 404, "NOT_FOUND", "route not found")
      return
    # /c/{slug}/settings
    if parts.len == 4 and parts[1] == "c" and parts[3] == "settings":
      let user = currentUser(request)
      if user.isNone:
        problem(request, 401, "UNAUTHENTICATED", "login required")
        return
      let (decision, ctx) = decide(user.get,
        cookieValue(request, "majadu_session"), parts[2],
        if verb == "GET": readAccess() else: writeAccess())
      if decision != gAllowed:
        respondGate(request, decision)
        return
      if verb == "GET":
        getCommunitySettings(request, ctx.get)
      elif verb == "PATCH":
        patchCommunitySettings(request, ctx.get, user.get)
      else:
        problem(request, 405, "METHOD", "")
      return
    # /c/{slug}/rankings
    if parts.len == 4 and parts[1] == "c" and parts[3] == "rankings":
      let user = currentUser(request)
      if user.isNone:
        problem(request, 401, "UNAUTHENTICATED", "login required")
        return
      let (decision, ctx) = decide(user.get,
        cookieValue(request, "majadu_session"), parts[2], readAccess())
      if decision != gAllowed:
        respondGate(request, decision)
        return
      rankings(request, ctx.get.communityId)
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
      if parts.len == 4 and parts[3] == "ws-ticket" and verb == "POST":
        issueShareTicket(request, code)
        return
    problem(request, 404, "NOT_FOUND", "route not found")
  except CatchableError as error:
    stderr.writeLine "app error: " & error.msg
    problem(request, 500, "INTERNAL", "internal error")

proc newApp*(db: Db, oidc: OidcConfig, keyring: Keyring,
             config: ConfigCache): App =
  App(db: db, oidc: oidc, keyring: keyring, config: config,
      limiter: newLimiter(),
      hub: newHub(db),
      cookieSecure: getEnv("MAJADU_COOKIE_SECURE") == "1",
      bootstrapOwner: getEnv("MAJADU_BOOTSTRAP_OWNER_EMAIL"))

proc install*(app: App) =
  application = app
  installHub(app.hub)

proc handler*(): RequestHandler =
  ## The App lives in a process-wide ref shared by every worker thread. Mummy
  ## requires a gcsafe handler; the cast is the single audited boundary, because
  ## `application` is assigned once at boot and never mutated afterwards.
  result = proc(request: Request) {.gcsafe.} =
    {.cast(gcsafe).}:
      route(request)
