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
import session/schedule as sessionSchedule
import ws_ticket as wsTicket
import platform/idempotency
import player/domain/player as playerDomain
import player/store as playerStore
import player/claim as playerClaim
import player/merge as playerMerge
import rating/domain/rating as ratingDomain
import rating/infrastructure/ingest as ratingIngest
import rating/infrastructure/params as ratingParams
import rating/read as ratingRead
import achievement/infrastructure/backfill as achievementBackfill
import account/domain/lifecycle as accountLifecycle
import account/domain/audit
import account/domain/roles
import account/infrastructure/audit_store
import account/infrastructure/jwt_rs256
import account/infrastructure/oidc
import account/infrastructure/ops_token as opsToken
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
  let subject = claims["sub"].getStr()
  let tombstone = application.db.queryOne(
    """select id, email_hash from platform.user where google_sub = $1""",
    @[textParam(sha256Hex(subject))])
  if tombstone.isSome and accountLifecycle.isAnonymized(
      tombstone.get.get("email_hash"), tombstone.get.get("id")):
    problem(request, 403, "ACCOUNT_ANONYMIZED", "this account was deactivated")
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
    @[textParam(subject), textParam(sha256Hex(email)),
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
    patchBody = sessionWrite.parsePatch(bodyJson(request))
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

proc playerLimit(request: Request): int =
  let fallback = configSnapshot().intValue(%*{}, keyApiPageSizeDefault)
  let raw = request.queryParams["limit"]
  if raw.len == 0:
    return fallback
  try:
    let value = parseInt(raw)
    if value < 1 or value > 1000:
      return fallback
    value
  except ValueError:
    fallback

proc listPlayersRoute(request: Request, ctx: CommunityContext) =
  let items = playerStore.list(application.db, ctx.communityId,
    playerLimit(request), request.queryParams["cursor"],
    request.queryParams["tier"], request.queryParams["q"])
  var body = newJArray()
  for item in items:
    body.add(item)
  jsonResponse(request, 200, %*{"items": body}, [("Cache-Control", "no-store")])

proc withAliases(player: JsonNode, aliases: seq[string]): JsonNode =
  result = player
  var list = newJArray()
  for alias in aliases:
    list.add(%alias)
  result["aliases"] = list

proc createPlayerRoute(request: Request, ctx: CommunityContext, user: AuthUser) =
  var body: JsonNode
  try:
    body = bodyJson(request)
  except ValueError:
    problem(request, 400, "INVALID_BODY", "body must be JSON")
    return
  let name = if body.hasKey("name") and body["name"].kind == JString:
    body["name"].getStr() else: ""
  let gender = if body.hasKey("gender") and body["gender"].kind == JString:
    body["gender"].getStr() else: "M"
  let tier = if body.hasKey("tier") and body["tier"].kind == JString:
    body["tier"].getStr() else: ""
  let problems = playerDomain.checkCreate(name, gender, tier)
  if problems.len > 0:
    problem(request, 400, "INVALID_PLAYER", $problems[0])
    return
  var aliases: seq[string] = @[]
  if body.hasKey("aliases"):
    try:
      aliases = playerDomain.parseAliases(body["aliases"])
    except ValueError as error:
      problem(request, 400, "INVALID_PLAYER", error.msg)
      return
    if not playerDomain.aliasesValid(aliases):
      problem(request, 400, "INVALID_ALIAS", "aliases must be distinct non-empty names")
      return
  let result = playerStore.create(application.db, ctx.communityId,
    playerDomain.normalizeName(name), gender.toUpperAscii(),
    if tier.len > 0: $playerDomain.parseTier(tier) else: "")
  case result.status
  of pcDuplicate:
    problem(request, 409, "PLAYER_EXISTS", "a player with this name already exists")
  of pcInvalid:
    problem(request, 400, "INVALID_PLAYER", "cannot create player")
  of pcOk:
    let playerId = result.player["id"].getStr()
    if aliases.len > 0 and
       not playerStore.setAliases(application.db, ctx.communityId, playerId, aliases):
      # The player had no aliases yet, so undo the insert rather than leaving a
      # half-created record behind.
      discard playerStore.remove(application.db, ctx.communityId, playerId)
      problem(request, 409, "ALIAS_TAKEN", "an alias is already used by another player")
      return
    audit("player.create", ctx.communityId, user, "player", playerId,
      %*{"name": result.player["name"]})
    jsonResponse(request, 201, withAliases(result.player,
      playerStore.aliases(application.db, ctx.communityId, playerId)))

proc getPlayerRoute(request: Request, ctx: CommunityContext, playerId: string) =
  let player = playerStore.get(application.db, ctx.communityId, playerId)
  if player.isNone:
    problem(request, 404, "NOT_FOUND", "player not found")
    return
  jsonResponse(request, 200,
    withAliases(player.get,
      playerStore.aliases(application.db, ctx.communityId, playerId)),
    [("Cache-Control", "no-store")])

proc patchPlayerRoute(request: Request, ctx: CommunityContext, user: AuthUser,
                      playerId: string) =
  var patch: playerDomain.PlayerPatch
  try:
    patch = playerDomain.parsePatch(bodyJson(request))
  except ValueError as error:
    problem(request, 400, "INVALID_PLAYER", error.msg)
    return
  var aliases: seq[string] = @[]
  if patch.aliases.isSome:
    aliases = patch.aliases.get
    if not playerDomain.aliasesValid(aliases):
      problem(request, 400, "INVALID_ALIAS", "aliases must be distinct non-empty names")
      return
  let result = playerStore.patch(application.db, ctx.communityId, playerId, patch)
  case result.status
  of psOk:
    if patch.aliases.isSome and
       not playerStore.setAliases(application.db, ctx.communityId, playerId, aliases):
      problem(request, 409, "ALIAS_TAKEN", "an alias is already used by another player")
      return
    audit("player.patch", ctx.communityId, user, "player", playerId,
      %*{"name": result.player["name"]})
    jsonResponse(request, 200, withAliases(result.player,
      playerStore.aliases(application.db, ctx.communityId, playerId)))
  of psDuplicate:
    problem(request, 409, "PLAYER_EXISTS", "a player with this name already exists")
  of psNotFound:
    problem(request, 404, "NOT_FOUND", "player not found")

proc mergePlayerRoute(request: Request, ctx: CommunityContext, user: AuthUser,
                        targetId: string) =
  var body: JsonNode
  try:
    body = bodyJson(request)
  except ValueError:
    problem(request, 400, "INVALID_BODY", "body must be JSON")
    return
  if not body.hasKey("sourcePlayerId") or body["sourcePlayerId"].kind != JString:
    problem(request, 400, "INVALID_BODY", "sourcePlayerId is required")
    return
  let sourceId = body["sourcePlayerId"].getStr()
  let outcome = playerMerge.merge(application.db, ctx.communityId, targetId,
    sourceId, user.id)
  case outcome.error
  of playerMerge.meOk:
    audit("player.merge", ctx.communityId, user, "player", targetId,
      %*{"sourcePlayerId": sourceId,
        "rowsMoved": outcome.result.aliasesMoved + outcome.result.claimsMoved +
          outcome.result.deltasMoved + outcome.result.snapshotsMoved +
          outcome.result.achievementsMoved + outcome.result.pairsMoved +
          outcome.result.ratingStateMoved})
    jsonResponse(request, 200, %*{
      "targetPlayerId": outcome.result.targetPlayerId,
      "sourcePlayerId": outcome.result.sourcePlayerId,
      "aliasesMoved": outcome.result.aliasesMoved,
      "claimsMoved": outcome.result.claimsMoved,
      "deltasMoved": outcome.result.deltasMoved,
      "snapshotsMoved": outcome.result.snapshotsMoved,
      "achievementsMoved": outcome.result.achievementsMoved,
      "pairsMoved": outcome.result.pairsMoved,
      "ratingStateMoved": outcome.result.ratingStateMoved})
  of playerMerge.mePlayerNotFound:
    problem(request, 404, "NOT_FOUND", "player not found")
  of playerMerge.meSamePlayer:
    problem(request, 400, "SAME_PLAYER", "source and target must differ")
  of playerMerge.mePairInUse:
    problem(request, 409, "MERGE_CONFLICT",
      "a tournament pair of both players is already used by a match")
  of playerMerge.meConflict:
    problem(request, 409, "MERGE_CONFLICT", "players cannot be merged")

proc deletePlayerRoute(request: Request, ctx: CommunityContext, user: AuthUser,
                       playerId: string) =
  if not playerStore.remove(application.db, ctx.communityId, playerId):
    problem(request, 404, "NOT_FOUND", "player not found")
    return
  audit("player.delete", ctx.communityId, user, "player", playerId)
  send(request, 204, @[("Cache-Control", "no-store")], "")

proc claimProblem(request: Request, error: playerClaim.ClaimError) =
  case error
  of cePlayerNotFound:
    problem(request, 404, "NOT_FOUND", "player not found")
  of ceAlreadyPending:
    problem(request, 409, "CLAIM_PENDING", "a claim for this player is pending")
  of ceAlreadyClaimed:
    problem(request, 409, "CLAIMED", "this player already has an owner")
  of ceClaimNotFound:
    problem(request, 404, "NOT_FOUND", "claim not found")
  of ceSelfDecision:
    problem(request, 403, "SELF_DECISION", "you cannot decide your own claim")
  of ceConflict:
    problem(request, 409, "CLAIM_CONFLICT", "claim changed after it was read")
  of ceOk:
    discard

proc listClaimsRoute(request: Request, ctx: CommunityContext, playerId: string) =
  var items = newJArray()
  for claim in playerClaim.list(application.db, ctx.communityId, playerId):
    items.add(%*{
      "id": claim.id,
      "userId": claim.userId,
      "status": claim.status,
      "decidedBy": claim.decidedBy,
      "decidedAt": claim.decidedAt,
      "reason": claim.reason,
      "createdAt": claim.createdAt,
    })
  jsonResponse(request, 200, %*{"items": items}, [("Cache-Control", "no-store")])

proc submitClaim(request: Request, ctx: CommunityContext, user: AuthUser,
                 playerId: string) =
  let result = playerClaim.submit(application.db, ctx.communityId, playerId, user.id)
  if result != ceOk:
    claimProblem(request, result)
    return
  audit("player.claim.submitted", ctx.communityId, user, "player", playerId)
  jsonResponse(request, 201, %*{"playerId": playerId, "status": "pending"})

proc decideClaim(request: Request, ctx: CommunityContext, user: AuthUser,
                 playerId, claimId: string) =
  var body: JsonNode
  try:
    body = bodyJson(request)
  except ValueError:
    problem(request, 400, "INVALID_BODY", "body must be JSON")
    return
  let action = if body.hasKey("action") and body["action"].kind == JString:
    body["action"].getStr() else: ""
  let reason = if body.hasKey("reason") and body["reason"].kind == JString:
    body["reason"].getStr() else: ""

  if action == "release":
    if reason.strip().len == 0:
      problem(request, 400, "REASON_REQUIRED", "releasing someone else needs a reason")
      return
    let subject = playerClaim.claimOwner(application.db, ctx.communityId, playerId,
      claimId)
    if subject.len == 0:
      problem(request, 404, "NOT_FOUND", "claim not found")
      return
    let released = playerClaim.release(application.db, ctx.communityId, playerId,
      user.id, claimId, subject, reason)
    if released != ceOk:
      claimProblem(request, released)
      return
    audit("player.claim.released", ctx.communityId, user, "claim", claimId,
      %*{"playerId": playerId, "status": "released"})
    jsonResponse(request, 200, %*{"claimId": claimId, "status": "released"})
    return

  let decision = if body.hasKey("decision") and body["decision"].kind == JString:
    body["decision"].getStr() else: ""
  if decision notin ["approve", "reject"]:
    problem(request, 400, "INVALID_DECISION", "decision must be approve or reject")
    return
  let result = playerClaim.decide(application.db, ctx.communityId, playerId,
    claimId, user.id, decision == "approve", reason)
  if result != ceOk:
    claimProblem(request, result)
    return
  audit(if decision == "approve": "player.claim.approved" else: "player.claim.rejected",
    ctx.communityId, user, "claim", claimId, %*{"playerId": playerId})
  jsonResponse(request, 200, %*{"claimId": claimId,
    "status": if decision == "approve": "approved" else: "rejected"})

proc releaseOwnClaim(request: Request, ctx: CommunityContext, user: AuthUser,
                     playerId: string) =
  let claimId = playerClaim.approvedClaimFor(application.db, ctx.communityId,
    playerId, user.id)
  if claimId.len == 0:
    problem(request, 409, "CLAIM_CONFLICT", "you have no approved claim here")
    return
  let released = playerClaim.release(application.db, ctx.communityId, playerId,
    user.id, claimId, user.id, "self_released")
  if released != ceOk:
    claimProblem(request, released)
    return
  audit("player.claim.released", ctx.communityId, user, "claim", claimId,
    %*{"playerId": playerId, "status": "released"})
  jsonResponse(request, 200, %*{"claimId": claimId, "status": "released"})

proc bearerToken(request: Request): string =
  let header = request.headers["Authorization"]
  if not header.startsWith("Bearer "):
    return ""
  header[7 .. ^1].strip()

proc opsPing(request: Request) =
  ## Ops routes accept only a bearer token. A valid browser cookie is not enough,
  ## and the same token never authenticates a web route because those read only
  ## the session cookie.
  let name = opsToken.verify(application.db, bearerToken(request))
  if name.isNone:
    problem(request, 401, "UNAUTHENTICATED", "ops token required")
    return
  jsonResponse(request, 200, %*{"ok": true, "token": name.get},
    [("Cache-Control", "no-store")])

proc ratingParamsFor(ctx: CommunityContext): ratingDomain.RatingParams =
  ratingParams.loadRatingParams(configSnapshot(),
    currentSettings(application.db, ctx.communityId))

proc ingestSessionRating(request: Request, ctx: CommunityContext,
                         sessionId: string) =
  let result = ratingIngest.ingestSession(application.db, ctx.communityId,
    sessionId, ratingParamsFor(ctx))
  jsonResponse(request, 200, %*{"events": result.events,
    "deltas": result.deltas}, [("Cache-Control", "no-store")])

proc clearSessionRating(request: Request, ctx: CommunityContext,
                        sessionId: string) =
  let removed = ratingIngest.revertSource(application.db, ctx.communityId, sessionId)
  let rebuilt = ratingIngest.rebuild(application.db, ctx.communityId,
    ratingParamsFor(ctx))
  jsonResponse(request, 200, %*{"removedDeltas": removed,
    "events": rebuilt.events, "deltas": rebuilt.deltas},
    [("Cache-Control", "no-store")])

proc rebuildRatings(request: Request, ctx: CommunityContext,
                    user: AuthUser) =
  let result = ratingIngest.rebuild(application.db, ctx.communityId,
    ratingParamsFor(ctx))
  audit("rating.rebuild", ctx.communityId, user, "community", ctx.communityId,
    %*{"events": result.events, "deltas": result.deltas})
  jsonResponse(request, 200, %*{"events": result.events,
    "deltas": result.deltas}, [("Cache-Control", "no-store")])

proc listRatingSources(request: Request, ctx: CommunityContext) =
  var items = newJArray()
  for row in application.db.query(
    """select e.id, e.event_type, e.local_date::text as local_date,
              coalesce(e.source_id::text, '') as source_id,
              count(d.id)::int as deltas
       from rating.events e
       left join rating.deltas d on d.event_id = e.id
       where e.community_id = $1::uuid
       group by e.id order by e.local_date desc, e.created_at desc""",
    @[textParam(ctx.communityId)]):
    items.add(%*{"id": row.get("id"), "type": row.get("event_type"),
      "date": row.get("local_date"), "sourceId": row.get("source_id"),
      "deltas": parseInt(row.get("deltas"))})
  jsonResponse(request, 200, %*{"items": items}, [("Cache-Control", "no-store")])

proc removeRatingSource(request: Request, ctx: CommunityContext, user: AuthUser,
                        eventId: string) =
  let removed = ratingIngest.removeEvent(application.db, ctx.communityId, eventId)
  let rebuilt = ratingIngest.rebuild(application.db, ctx.communityId,
    ratingParamsFor(ctx))
  audit("rating.source.delete", ctx.communityId, user, "rating_event", eventId,
    %*{"removedDeltas": removed})
  jsonResponse(request, 200, %*{"removedDeltas": removed,
    "events": rebuilt.events, "deltas": rebuilt.deltas},
    [("Cache-Control", "no-store")])

proc sessionVersionNow(communityId, sessionId: string): int =
  let row = application.db.queryOne(
    """select version from session.sessions
       where community_id = $1::uuid and id = $2::uuid""",
    @[textParam(communityId), textParam(sessionId)])
  if row.isSome: parseInt(row.get.get("version")) else: 0

proc scheduleProblem(request: Request, status: sessionSchedule.ScheduleStatus) =
  case status
  of sessionSchedule.ssOk:
    discard
  of sessionSchedule.ssNotFound:
    problem(request, 404, "NOT_FOUND", "session or game not found")
  of sessionSchedule.ssStale:
    problem(request, 412, "STALE_VERSION", "session changed since If-Match")
  of sessionSchedule.ssInvalid:
    problem(request, 400, "INVALID_SCHEDULE", "schedule body is invalid")
  of sessionSchedule.ssUnknownPlayer:
    problem(request, 400, "UNKNOWN_PLAYER", "player is not in this community")

proc scheduleDone(request: Request, ctx: CommunityContext, sessionId: string,
                  status: sessionSchedule.ScheduleStatus) =
  if status != sessionSchedule.ssOk:
    scheduleProblem(request, status)
    return
  let version = sessionVersionNow(ctx.communityId, sessionId)
  application.hub.sessionChanged(sessionId, version)
  jsonResponse(request, 200, %*{"version": version},
    [("ETag", "\"" & $version & "\""), ("Cache-Control", "no-store")])

proc putScheduleRoute(request: Request, ctx: CommunityContext, sessionId: string) =
  let version = requireIfMatch(request)
  if version.isNone: return
  var games: seq[sessionSchedule.GameSpec]
  try:
    games = sessionSchedule.parseSchedule(bodyJson(request))
  except ValueError as error:
    problem(request, 400, "INVALID_SCHEDULE", error.msg)
    return
  scheduleDone(request, ctx, sessionId,
    sessionSchedule.putSchedule(application.db, ctx.communityId, sessionId,
      version.get, games))

proc setAbsentRoute(request: Request, ctx: CommunityContext, sessionId: string) =
  let version = requireIfMatch(request)
  if version.isNone: return
  var playerIds: seq[string]
  try:
    playerIds = sessionSchedule.parsePlayerIds(bodyJson(request))
  except ValueError as error:
    problem(request, 400, "INVALID_SCHEDULE", error.msg)
    return
  scheduleDone(request, ctx, sessionId,
    sessionSchedule.setAbsent(application.db, ctx.communityId, sessionId,
      version.get, playerIds))

proc setGameScoreRoute(request: Request, ctx: CommunityContext, sessionId,
                       gameKey: string) =
  let version = requireIfMatch(request)
  if version.isNone: return
  var body: JsonNode
  try:
    body = bodyJson(request)
  except ValueError:
    problem(request, 400, "INVALID_BODY", "body must be JSON")
    return
  if not body.hasKey("scoreA") or not body.hasKey("scoreB") or
     body["scoreA"].kind != JInt or body["scoreB"].kind != JInt:
    problem(request, 400, "INVALID_SCORE", "scoreA and scoreB are required")
    return
  scheduleDone(request, ctx, sessionId,
    sessionSchedule.setScore(application.db, ctx.communityId, sessionId, gameKey,
      version.get, body["scoreA"].getInt(), body["scoreB"].getInt()))

proc skipGameRoute(request: Request, ctx: CommunityContext, sessionId,
                   gameKey: string) =
  let version = requireIfMatch(request)
  if version.isNone: return
  scheduleDone(request, ctx, sessionId,
    sessionSchedule.skipGame(application.db, ctx.communityId, sessionId, gameKey,
      version.get))

proc getGameRoute(request: Request, ctx: CommunityContext, sessionId,
                  gameKey: string) =
  let key = sessionSchedule.parseGameKey(gameKey)
  if key.isNone:
    problem(request, 400, "INVALID_GAME_KEY", "gameKey must be round-court")
    return
  let row = application.db.queryOne(
    """select round_no, court_no, score_a, score_b, status,
              coalesce(side_a1::text, '') as side_a1,
              coalesce(side_a2::text, '') as side_a2,
              coalesce(side_b1::text, '') as side_b1,
              coalesce(side_b2::text, '') as side_b2
       from session.games
       where community_id = $1::uuid and session_id = $2::uuid
         and round_no = $3 and court_no = $4""",
    @[textParam(ctx.communityId), textParam(sessionId),
      intParam(key.get[0].int64), intParam(key.get[1].int64)])
  if row.isNone:
    problem(request, 404, "NOT_FOUND", "game not found")
    return
  var sideA = newJArray()
  var sideB = newJArray()
  for slot in ["side_a1", "side_a2"]:
    if row.get.get(slot).len > 0: sideA.add(%row.get.get(slot))
  for slot in ["side_b1", "side_b2"]:
    if row.get.get(slot).len > 0: sideB.add(%row.get.get(slot))
  jsonResponse(request, 200, %*{
    "round": parseInt(row.get.get("round_no")),
    "court": parseInt(row.get.get("court_no")),
    "sideA": sideA, "sideB": sideB,
    "scoreA": if row.get["score_a"].isNone: newJNull() else: %parseInt(row.get.get("score_a")),
    "scoreB": if row.get["score_b"].isNone: newJNull() else: %parseInt(row.get.get("score_b")),
    "status": row.get.get("status")}, [("Cache-Control", "no-store")])

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

proc communityToday(timezone: string): string =
  ## The board window is a calendar question, so "today" is the community's day,
  ## not the server's.
  let row = application.db.queryOne(
    "select (now() at time zone $1)::date::text as today",
    @[textParam(timezone)])
  row.get.get("today")

proc boardItems(rows: seq[ratingRead.BoardRow]): JsonNode =
  var items = newJArray()
  for index, row in rows:
    items.add(%*{"rank": index + 1, "playerId": row.playerId, "name": row.name,
      "tier": if row.tier.len == 0: newJNull() else: %row.tier,
      "points": row.points, "games": row.games, "wins": row.wins,
      "losses": row.losses})
  items

proc communityBoard(request: Request, communityId, timezone: string) =
  let settings = currentSettings(application.db, communityId)
  let params = ratingParams.loadRatingParams(configSnapshot(), settings)
  let limit = configSnapshot().intValue(settings, keyRankBoardLimit)
  let query = ratingRead.BoardQuery(communityId: communityId,
    asOf: communityToday(timezone), params: params, limit: limit,
    tier: request.queryParams["tier"])
  let rows = ratingRead.board(application.db, query)
  jsonResponse(request, 200, %*{"items": boardItems(rows),
    "asOf": communityToday(timezone)}, [("Cache-Control", "no-store")])

proc rankingPlayer(request: Request, ctx: CommunityContext, playerId: string) =
  let params = ratingParamsFor(ctx)
  let limit = configSnapshot().intValue(
    currentSettings(application.db, ctx.communityId), keyRankBoardLimit)
  let query = ratingRead.BoardQuery(communityId: ctx.communityId,
    asOf: communityToday(ctx.timezone), params: params, limit: limit, tier: "")
  let entry = ratingRead.boardEntry(application.db, query, playerId)
  if entry.isNone:
    problem(request, 404, "NOT_FOUND", "player is not on the board")
    return
  let rank = ratingRead.rankOf(application.db, query, playerId)
  jsonResponse(request, 200, %*{"rank": rank, "playerId": entry.get.playerId,
    "name": entry.get.name,
    "tier": if entry.get.tier.len == 0: newJNull() else: %entry.get.tier,
    "points": entry.get.points, "games": entry.get.games,
    "wins": entry.get.wins, "losses": entry.get.losses},
    [("Cache-Control", "no-store")])

proc playerAchievements(request: Request, ctx: CommunityContext,
                        playerId: string) =
  let items = achievementBackfill.listForPlayer(application.db,
    ctx.communityId, playerId)
  var body = newJArray()
  for item in items:
    body.add(item)
  jsonResponse(request, 200, %*{"items": body}, [("Cache-Control", "no-store")])

proc playerStats(request: Request, ctx: CommunityContext, playerId: string) =
  let found = ratingRead.stats(application.db, ctx.communityId, playerId)
  if found.isNone:
    problem(request, 404, "NOT_FOUND", "player not found")
    return
  jsonResponse(request, 200, found.get, [("Cache-Control", "no-store")])

proc getSharedRankings(request: Request, code: string) =
  let found = shareStore.resolve(application.db, application.keyring, code)
  if found.isNone:
    problem(request, 404, "NOT_FOUND", "link not found")
    return
  communityBoard(request, found.get.communityId, found.get.timezone)

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
    if path.startsWith("/ops/"):
      if path == "/ops/ping" and request.httpMethod == "GET":
        opsPing(request)
      else:
        problem(request, 404, "NOT_FOUND", "route not found")
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
    # /c/{slug}/players[/{id}]
    if parts.len >= 4 and parts[1] == "c" and parts[3] == "players":
      let user = currentUser(request)
      if user.isNone:
        problem(request, 401, "UNAUTHENTICATED", "login required")
        return
      let access =
        if parts.len >= 6: readAccess()
        elif verb == "GET": readAccess()
        elif verb == "DELETE": Access(isSession: true, roles: @[rAdmin])
        else: writeAccess()
      let (decision, ctx) = decide(user.get,
        cookieValue(request, "majadu_session"), parts[2], access)
      if decision != gAllowed:
        respondGate(request, decision)
        return
      if parts.len == 4 and verb == "GET":
        listPlayersRoute(request, ctx.get)
        return
      if parts.len == 4 and verb == "POST":
        createPlayerRoute(request, ctx.get, user.get)
        return
      if parts.len == 5 and verb == "GET":
        getPlayerRoute(request, ctx.get, parts[4])
        return
      if parts.len == 5 and verb == "PATCH":
        patchPlayerRoute(request, ctx.get, user.get, parts[4])
        return
      if parts.len == 5 and verb == "DELETE":
        deletePlayerRoute(request, ctx.get, user.get, parts[4])
        return
      if parts.len == 6 and parts[5] == "achievements" and verb == "GET":
        playerAchievements(request, ctx.get, parts[4])
        return
      if parts.len == 6 and parts[5] == "stats" and verb == "GET":
        playerStats(request, ctx.get, parts[4])
        return
      if parts.len == 6 and parts[5] == "merge" and verb == "POST":
        let admin = adminGate(request, parts[2])
        if admin.isNone: return
        mergePlayerRoute(request, admin.get[1], admin.get[0], parts[4])
        return
      if parts.len == 6 and parts[5] == "claims":
        if verb == "GET":
          listClaimsRoute(request, ctx.get, parts[4])
          return
        if verb == "POST":
          submitClaim(request, ctx.get, user.get, parts[4])
          return
      if parts.len == 7 and parts[5] == "claims" and verb == "PATCH":
        let admin = adminGate(request, parts[2])
        if admin.isNone: return
        decideClaim(request, admin.get[1], admin.get[0], parts[4], parts[6])
        return
      if parts.len == 6 and parts[5] == "claim" and verb == "DELETE":
        releaseOwnClaim(request, ctx.get, user.get, parts[4])
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
      if parts.len == 6 and parts[5] == "rating":
        if verb in ["POST", "DELETE"]:
          let admin = adminGate(request, parts[2])
          if admin.isNone: return
          if verb == "POST":
            ingestSessionRating(request, admin.get[1], parts[4])
          else:
            clearSessionRating(request, admin.get[1], parts[4])
          return
      if parts.len == 6 and parts[5] == "schedule" and verb == "PUT":
        putScheduleRoute(request, ctx.get, parts[4])
        return
      if parts.len == 6 and parts[5] == "absent" and verb == "PATCH":
        setAbsentRoute(request, ctx.get, parts[4])
        return
      if parts.len == 7 and parts[5] == "games":
        if verb == "GET":
          getGameRoute(request, ctx.get, parts[4], parts[6])
          return
        if verb == "PATCH":
          setGameScoreRoute(request, ctx.get, parts[4], parts[6])
          return
      if parts.len == 8 and parts[5] == "games" and parts[7] == "skip" and
         verb == "PATCH":
        skipGameRoute(request, ctx.get, parts[4], parts[6])
        return
    # /c/{slug}/ratings/rebuild and /c/{slug}/rating-sources[/{id}]
    if parts.len >= 4 and parts[1] == "c" and
       parts[3] in ["ratings", "rating-sources"]:
      let admin = adminGate(request, parts[2])
      if admin.isNone: return
      if parts[3] == "ratings" and parts.len == 5 and parts[4] == "rebuild" and
         verb == "POST":
        rebuildRatings(request, admin.get[1], admin.get[0])
        return
      if parts[3] == "rating-sources" and parts.len == 4 and verb == "GET":
        listRatingSources(request, admin.get[1])
        return
      if parts[3] == "rating-sources" and parts.len == 5 and verb == "DELETE":
        removeRatingSource(request, admin.get[1], admin.get[0], parts[4])
        return
      problem(request, 404, "NOT_FOUND", "route not found")
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
    # /c/{slug}/rankings[/{playerId}]
    if parts.len in [4, 5] and parts[1] == "c" and parts[3] == "rankings":
      let user = currentUser(request)
      if user.isNone:
        problem(request, 401, "UNAUTHENTICATED", "login required")
        return
      let (decision, ctx) = decide(user.get,
        cookieValue(request, "majadu_session"), parts[2], readAccess())
      if decision != gAllowed:
        respondGate(request, decision)
        return
      if parts.len == 4:
        communityBoard(request, ctx.get.communityId, ctx.get.timezone)
      else:
        rankingPlayer(request, ctx.get, parts[4])
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
