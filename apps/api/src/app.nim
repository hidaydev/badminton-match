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
import logger
# `templateRoute` (rate-limit labels) is the only symbol used here; the counter
# registry is never incremented and no route renders it.
import metrics
import ratelimit
import security_headers
import server
import db/db
import sha256
import uuidv7
import share/crypto
import share/store as shareStore
import session/write as sessionWrite
import session/standings as sessionStandings
import session/schedule as sessionSchedule
import session/swap as sessionSwap
import tournament/store as tournamentStore
import ws_ticket as wsTicket
import platform/idempotency
import player/domain/player as playerDomain
import player/store as playerStore
import player/claim as playerClaim
import player/merge as playerMerge
import rating/domain/rating as ratingDomain
import rating/infrastructure/ingest as ratingIngest
import rating/infrastructure/tournament as ratingTournament
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

# The running build reports its version from the repository VERSION file, so a
# release and `GET /version` cannot drift. A build may override both values.
const
  appVersion* {.strdefine.} = staticRead("../../../VERSION").strip()
  appCommit* {.strdefine.} = "none"
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
           after: JsonNode = newJObject(), role = "") =
  ## Every privileged write leaves evidence. Field names outside the domain
  ## allowlist are dropped inside the adapter, never written. The role is what
  ## the membership actually granted, so a host write does not read as admin.
  recordAudit(application.db, auditEvent(action, communityId,
    actorId = user.id,
    actorRole = (if user.isOwner: "platform_owner"
                 elif role.len > 0: role
                 else: "admin"),
    targetKind = targetKind, targetId = targetId, requestId = uuidv7()).withEvidence(
      newJObject(), after))

proc audit(action: string, ctx: CommunityContext, user: AuthUser,
           targetKind: string, targetId: string,
           after: JsonNode = newJObject()) =
  ## Community route overload: the membership role is already resolved.
  audit(action, ctx.communityId, user, targetKind, targetId, after, $ctx.role)

proc authAudit(action: string, user: AuthUser, outcome = arAllow,
               reason = "") =
  ## Auth events belong to no community, so the row carries none. The role is
  ## the platform one, because a lesson learned here is about a person's
  ## sessions, not about a membership.
  recordAudit(application.db, auditEvent(action, communityId = "",
    actorId = user.id,
    actorRole = (if user.isOwner: "platform_owner" else: "member"),
    outcome = outcome, targetKind = "user", targetId = user.id,
    reason = reason, requestId = uuidv7()))

proc authRejected(action, reason: string, userId = "") =
  ## A rejected attempt before any session exists: who is unknown unless the
  ## account was already resolved. Only the reason is kept, never the token.
  recordAudit(application.db, auditEvent(action, communityId = "",
    actorId = userId, actorRole = "anonymous", outcome = arDeny,
    targetKind = (if userId.len > 0: "user" else: ""), targetId = userId,
    reason = reason, requestId = uuidv7()))

proc send(request: Request, status: int,
          headers: openArray[(string, string)], body: string) =
  ## Single response path: every response carries the security headers, so a new
  ## route cannot silently ship without CSP or nosniff.
  var merged = @headers
  for pair in securityHeaders(application.cookieSecure):
    merged.add(pair)
  request.respond(status, merged, body)
  recordResponse(request.httpMethod, request.path, status)

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

proc cookieValue(request: Request, name: string): string =
  let header = request.headers["Cookie"]
  for part in header.split(';'):
    let pair = part.strip().split('=', maxsplit = 1)
    if pair.len == 2 and pair[0] == name:
      return pair[1]
  ""

proc configSnapshot(): Snapshot =
  application.config.snapshot(application.db)

proc bodyJson(request: Request): JsonNode =
  if request.body.len == 0:
    return %*{}
  # Refused before parsing: `parseJson` walks the nesting, so the depth can only
  # be checked on the raw text. `/auth/start` is unauthenticated and parses
  # before anything else, which is why this door enforces the limit.
  if jsonTooDeep(request.body,
      configSnapshot().intValue(%*{}, keySecurityMaxJsonDepth)):
    raise newException(ValueError, "body is nested too deeply")
  let parsed =
    try:
      parseJson(request.body)
    except JsonParsingError:
      raise newException(ValueError, "invalid JSON body")
  # Every route reads the body as an object. A valid scalar or array would reach
  # `hasKey` and raise a defect, which the handler reports as a 500.
  if parsed.kind != JObject:
    raise newException(ValueError, "body must be a JSON object")
  parsed

proc requestIdentity(request: Request): string =
  ## Production sits behind a CDN edge, so the TCP-derived address is the same
  ## for everyone and a per-address quota would be a platform-wide quota. A
  ## browser with a session cookie is keyed by a hash of that cookie; an
  ## anonymous caller keeps the address. The table is memory-only, so the token
  ## itself is never stored.
  let token = cookieValue(request, "majadu_session")
  if token.len > 0: "session:" & sha256Hex(token)[0 .. 15]
  else: clientIp(request, trustedProxies())

proc rateLimited(request: Request, decision: Decision) =
  send(request, 429,
    @[("Content-Type", "application/json"), ("Cache-Control", "no-store"),
      ("Retry-After", $decision.retryAfter)],
    $ %*{"status": 429, "code": "RATE_LIMITED",
         "retryAfter": decision.retryAfter})

proc sessionCookie(token: string): string =
  let days = configSnapshot().intValue(%*{}, keySessionAbsoluteDays)
  result = "majadu_session=" & token &
    "; Path=/; HttpOnly; SameSite=Lax; Max-Age=" & $(days * 86400)
  if application.cookieSecure:
    result.add("; Secure")

proc authFlowCookie(state: string): string =
  ## Binds an OIDC flow to the browser that started it. Without it an attacker
  ## can start the flow themselves and hand the callback URL to a victim, who
  ## then ends up signed in as the attacker (login CSRF). The value is a hash of
  ## the state, so the cookie is useless on its own and a mismatch is cheap.
  ## No Max-Age on purpose: this is a session cookie, and the flow row in the
  ## database already carries the expiry.
  result = "majadu_auth_flow=" & sha256Hex(state) &
    "; Path=/; HttpOnly; SameSite=Lax"
  if application.cookieSecure:
    result.add("; Secure")

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
  var body: JsonNode
  try:
    body = bodyJson(request)
  except ValueError:
    problem(request, 400, "INVALID_BODY", "body must be JSON")
    return
  let returnTo =
    if body.hasKey("returnTo"): body["returnTo"].getStr() else: "/"
  let safeReturn = safeReturnPath(returnTo)
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
  }, [("Set-Cookie", authFlowCookie(state))])

proc finishAuth(request: Request) =
  let code = request.queryParams["code"]
  let state = request.queryParams["state"]
  if code.len == 0 or state.len == 0:
    problem(request, 400, "INVALID_CALLBACK", "code and state are required")
    return
  # Checked before the flow row is consumed, so a callback posted from a foreign
  # browser cannot burn a flow that belongs to someone else.
  if cookieValue(request, "majadu_auth_flow") != sha256Hex(state):
    authRejected("auth.login.rejected", "flow cookie missing or foreign")
    problem(request, 400, "INVALID_STATE",
      "flow not found, expired or already used")
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
    authRejected("auth.login.rejected", "invalid id token")
    problem(request, 401, "INVALID_ID_TOKEN", error.msg)
    return
  if sha256Hex(claims["nonce"].getStr()) != flow.get("nonce_hash"):
    authRejected("auth.login.rejected", "nonce mismatch")
    problem(request, 401, "NONCE_MISMATCH", "nonce mismatch")
    return
  let subject = claims["sub"].getStr()
  let tombstone = application.db.queryOne(
    """select id, email_hash from platform.user where google_sub = $1""",
    @[textParam(sha256Hex(subject))])
  if tombstone.isSome and accountLifecycle.isAnonymized(
      tombstone.get.get("email_hash"), tombstone.get.get("id")):
    authRejected("auth.login.rejected", "account anonymized",
      tombstone.get.get("id"))
    problem(request, 403, "ACCOUNT_ANONYMIZED", "this account was deactivated")
    return
  # One normalization for the whole flow: invites are stored lowercased, so a
  # provider that echoes the address with different capitals would otherwise
  # never match its pending row.
  let email = claims["email"].getStr().strip().toLowerAscii()
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
       returning id, is_platform_owner""",
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
  authAudit("auth.login", AuthUser(id: userRow.get.get("id"),
    isOwner: userRow.get.get("is_platform_owner") == "t"))
  send(request, 302,
    @[("Location", safeReturnPath(flow.get("return_to"))),
      ("Set-Cookie", sessionCookie(token)),
      ("Set-Cookie",
        "majadu_auth_flow=; Path=/; HttpOnly; SameSite=Lax; Max-Age=0")], "")

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
  authAudit("auth.sessions.revoke_others", user.get)
  send(request, 204, @[("Cache-Control", "no-store")], "")

proc me(request: Request) =
  let user = requireUser(request)
  if user.isNone: return
  ## The body names the caller, so a shared cache must never hold it.
  jsonResponse(request, 200, %*{
    "id": user.get.id,
    "displayName": user.get.displayName,
    "platformOwner": user.get.isOwner,
  }, [("Cache-Control", "no-store")])

proc logout(request: Request) =
  let token = cookieValue(request, "majadu_session")
  let user = currentUser(request)
  if token.len > 0:
    revoke(application.db, token)
  # Sockets and every ticket of the principal close with the session.
  if user.isSome:
    application.hub.revokePrincipal(user.get.id)
    authAudit("auth.logout", user.get)
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
  # The zone decides which calendar day a session belongs to, so an unknown name
  # is a bad request, not a value to store and fail on later.
  let zone = application.db.queryOne(
    "select 1 as ok from pg_timezone_names where name = $1",
    @[textParam(check.timezone)])
  if zone.isNone:
    problem(request, 400, "INVALID_COMMUNITY",
      "timezone is not a known IANA zone")
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

proc jsonString(body: JsonNode, key: string): string =
  if body[key].kind != JString:
    raise newException(ValueError, key & " must be a string")
  body[key].getStr()

proc validSessionDate(value: string): bool =
  ## A real calendar day in YYYY-MM-DD; the round trip rejects 2026-02-30.
  try:
    parse(value, "yyyy-MM-dd", utc()).format("yyyy-MM-dd") == value
  except TimeParseError:
    false

proc validClockTime(value: string): bool =
  ## HH:MM with two-digit fields, so "9:00" is refused rather than guessed.
  try:
    parse(value, "HH:mm", utc()).format("HH:mm") == value
  except TimeParseError:
    false

proc idempotentWrite(request: Request, userId, communityId, key: string,
                     body: string, resource = ""): Option[JsonNode]

proc createSession(request: Request, ctx: CommunityContext, user: AuthUser) =
  var body: JsonNode
  try:
    body = bodyJson(request)
  except ValueError:
    problem(request, 400, "INVALID_BODY", "body must be JSON")
    return
  var title = ""
  var date = ""
  var startTime = "00:00"
  var slot = 30
  try:
    # `getStr`/`getInt` answer their default on a kind mismatch, so each field
    # is type-checked before it is read: a numeric title must not become "".
    if body.hasKey("title"): title = jsonString(body, "title")
    if body.hasKey("date"): date = jsonString(body, "date")
    if body.hasKey("startTime"): startTime = jsonString(body, "startTime")
    if body.hasKey("slotMinutes"):
      if body["slotMinutes"].kind != JInt:
        raise newException(ValueError, "slotMinutes must be an integer")
      slot = body["slotMinutes"].getInt()
  except ValueError:
    problem(request, 400, "INVALID_BODY",
      "title, date, startTime and slotMinutes must have the documented types")
    return
  # Without these checks the insert reached PostgreSQL and a bad date, time or
  # slot became a 500. The contract already documents a 400 for this route.
  if not validSessionDate(date):
    problem(request, 400, "INVALID_BODY", "date must be a real YYYY-MM-DD day")
    return
  if not validClockTime(startTime):
    problem(request, 400, "INVALID_BODY", "startTime must be HH:MM")
    return
  if slot < 1 or slot > 240:
    problem(request, 400, "INVALID_BODY", "slotMinutes must be between 1 and 240")
    return
  try:
    # A blank title used to be stored as-is, so the list showed nameless
    # drafts; the create form always sends one.
    title = sessionWrite.parseTitle(title)
  except ValueError as error:
    problem(request, 400, "INVALID_BODY", error.msg)
    return
  # Claim the key only once the body is known to be valid: a 400 must not leave
  # the key owned, or every retry would answer 409 for the rest of the day.
  let key = request.headers["Idempotency-Key"]
  if idempotentWrite(request, user.id, ctx.communityId, key,
      request.body).isSome:
    return
  let row = application.db.queryOne(
    """insert into session.sessions
       (community_id, title, session_date, start_time, slot_minutes, status, source)
       values ($1, $2, $3::date, $4::time, $5, 'draft', 'manual')
       returning id, title, session_date::text as session_date, status""",
    @[textParam(ctx.communityId), textParam(title), textParam(date),
      textParam(startTime), intParam(slot.int64)])
  if row.isNone:
    # Nothing was written, so release the key instead of leaving it owned until
    # the TTL turns every retry into a 409.
    if key.len > 0:
      discard application.db.execUpdate(
        """delete from platform.idempotency_keys
           where user_id = $1::uuid and key = $2""",
        @[textParam(user.id), textParam(scopedKey(ctx.communityId, key))])
    problem(request, 400, "INVALID_SESSION", "cannot create session")
    return
  let created = %*{
    "id": row.get.get("id"),
    "title": row.get.get("title"),
    "date": row.get.get("session_date"),
    "status": row.get.get("status"),
  }
  # Complete before the audit: a failure while recording the event must not
  # leave a claimed key whose response was never stored.
  if key.len > 0:
    complete(application.db, user.id, scopedKey(ctx.communityId, key), 201,
      created)
  audit("session.create", ctx, user, "session", row.get.get("id"),
    %*{"title": row.get.get("title"), "date": row.get.get("session_date"),
        "status": row.get.get("status")})
  jsonResponse(request, 201, created)

proc listSessions(request: Request, ctx: CommunityContext) =
  ## One page, never a silently truncated history: the caller pages with
  ## `offset` and filters on the server, so a search is not limited to the
  ## newest page.
  let configured = configSnapshot().intValue(%*{}, keyApiPageSizeDefault)
  var limit = configured
  let rawLimit = request.queryParams["limit"]
  if rawLimit.len > 0:
    try:
      limit = parseInt(rawLimit)
    except ValueError:
      limit = configured
  limit = max(1, min(limit, 500))
  var offset = 0
  let rawOffset = request.queryParams["offset"]
  if rawOffset.len > 0:
    try:
      offset = max(0, parseInt(rawOffset))
    except ValueError:
      offset = 0
  var date = request.queryParams["date"]
  if date.len > 0 and not validSessionDate(date):
    date = ""
  let q = request.queryParams["q"].strip()
  var items = newJArray()
  for row in application.db.query(
    """select s.id, s.title, s.session_date::text as session_date, s.status,
              s.version,
              (select count(*) from session.participants p
                where p.community_id = s.community_id
                  and p.session_id = s.id)::int as player_count,
              (select count(*) from session.games g
                where g.community_id = s.community_id
                  and g.session_id = s.id)::int as total_games
       from session.sessions s
       where s.community_id = $1::uuid
         and ($2 = '' or s.session_date = nullif($2, '')::date)
         and ($3 = '' or s.title ilike '%' || $3 || '%')
       order by s.session_date desc, s.updated_at desc
       limit $4 offset $5""",
    @[textParam(ctx.communityId), textParam(date), textParam(q),
      intParam(limit.int64), intParam(offset.int64)]):
    items.add(%*{"id": row.get("id"), "title": row.get("title"),
      "date": row.get("session_date"), "status": row.get("status"),
      "version": parseInt(row.get("version")),
      "playerCount": parseInt(row.get("player_count")),
      "totalGames": parseInt(row.get("total_games"))})
  let totalRow = application.db.queryOne(
    """select count(*)::int as total from session.sessions s
       where s.community_id = $1::uuid
         and ($2 = '' or s.session_date = nullif($2, '')::date)
         and ($3 = '' or s.title ilike '%' || $3 || '%')""",
    @[textParam(ctx.communityId), textParam(date), textParam(q)])
  let total = if totalRow.isSome: parseInt(totalRow.get.get("total")) else: 0
  let nextCursor =
    if offset + items.len < total: $(offset + limit) else: ""
  jsonResponse(request, 200, %*{"items": items, "total": total,
    "nextCursor": nextCursor})

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
  audit("share.issue", ctx, user, "session", sessionId,
    %*{"sessionId": sessionId})
  jsonResponse(request, 201, %*{"code": code, "sessionId": sessionId})

proc deleteShareLink(request: Request, ctx: CommunityContext, user: AuthUser,
                     sessionId: string) =
  let revoked = shareStore.revokeLive(application.db, ctx.communityId, sessionId)
  if revoked.len == 0:
    problem(request, 404, "NOT_FOUND", "no live share link")
    return
  for linkId in revoked:
    application.hub.revokeShare(linkId)
  audit("share.revoke", ctx, user, "session", sessionId,
    %*{"sessionId": sessionId})
  send(request, 204, @[("Cache-Control", "no-store")], "")

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

proc ifNoneMatchHits(request: Request, etag: string): bool =
  ## Conditional read for the session detail route. Only If-None-Match is read,
  ## so the optimistic-concurrency If-Match path stays exactly as it was.
  let header = request.headers["If-None-Match"].strip()
  if header.len == 0:
    return false
  for raw in header.split(','):
    var candidate = raw.strip()
    if candidate.len >= 2 and candidate[0 .. 1].toLowerAscii() == "w/":
      candidate = candidate[2 .. ^1].strip()
    if candidate == "*" or candidate == etag:
      return true
  false

proc idempotencyKey(communityId, key, resource: string): string =
  ## The key is scoped to the resource the write touches. Without the resource,
  ## the same key and body sent to two different sessions or tournaments
  ## replayed the first response and left the second unchanged.
  scopedKey(communityId & (if resource.len > 0: "/" & resource else: ""), key)

proc releaseIdempotencyKey(userId, communityId, key, resource: string) =
  ## A failed attempt must not own the key: the retry with a corrected body
  ## would otherwise answer 409 for the rest of the TTL.
  if key.len == 0:
    return
  discard application.db.execUpdate(
    """delete from platform.idempotency_keys
       where user_id = $1::uuid and key = $2""",
    @[textParam(userId),
      textParam(idempotencyKey(communityId, key, resource))])

proc idempotentWrite(request: Request, userId, communityId, key: string,
                     body: string, resource = ""): Option[JsonNode] =
  ## Returns the stored response for a replay, a 409 body for a conflict, and
  ## none when the caller must do the work.
  if key.len == 0:
    return none(JsonNode)
  let scoped = idempotencyKey(communityId, key, resource)
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
  let resource = "session/" & sessionId
  if idempotentWrite(request, user.id, ctx.communityId, key, request.body,
      resource).isSome:
    return
  var patchBody: SessionPatch
  try:
    patchBody = sessionWrite.parsePatch(bodyJson(request))
  except ValueError as error:
    releaseIdempotencyKey(user.id, ctx.communityId, key, resource)
    problem(request, 400, "INVALID_PATCH", error.msg)
    return
  # The patch used to hand raw strings to `::date` / `::time`: a bad day became
  # a 500 and a loose "9:00" was normalised where create rejects it.
  if patchBody.date.isSome and not validSessionDate(patchBody.date.get):
    releaseIdempotencyKey(user.id, ctx.communityId, key, resource)
    problem(request, 400, "INVALID_PATCH", "date must be a real YYYY-MM-DD day")
    return
  if patchBody.startTime.isSome and not validClockTime(patchBody.startTime.get):
    releaseIdempotencyKey(user.id, ctx.communityId, key, resource)
    problem(request, 400, "INVALID_PATCH", "startTime must be HH:MM")
    return
  let result = sessionWrite.patch(application.db, ctx.communityId, sessionId,
    version.get, patchBody)
  case result.status
  of wsOk:
    audit("session.patch", ctx, user, "session", sessionId,
      result.record)
    if key.len > 0:
      complete(application.db, user.id,
        idempotencyKey(ctx.communityId, key, resource), 200, result.record)
    application.hub.sessionChanged(sessionId, result.record["version"].getInt())
    jsonResponse(request, 200, result.record,
      [("ETag", "\"" & $result.record["version"].getInt() & "\""),
       ("Cache-Control", "no-store")])
  of wsStale:
    releaseIdempotencyKey(user.id, ctx.communityId, key, resource)
    problem(request, 412, "STALE_VERSION", "session changed since If-Match")
  of wsNotFound:
    releaseIdempotencyKey(user.id, ctx.communityId, key, resource)
    problem(request, 404, "NOT_FOUND", "session not found")
  of wsInvalid:
    releaseIdempotencyKey(user.id, ctx.communityId, key, resource)
    problem(request, 400, "INVALID_PATCH", "cannot apply patch")

proc swapSession(request: Request, ctx: CommunityContext, user: AuthUser,
                 sessionId: string) =
  ## Session-level OCC: an If-Match version, one transaction, then the same
  ## `session.changed` broadcast every other schedule write sends.
  let version = requireIfMatch(request)
  if version.isNone: return
  let key = request.headers["Idempotency-Key"]
  let resource = "session/" & sessionId & "/swap"
  if idempotentWrite(request, user.id, ctx.communityId, key,
      request.body, resource).isSome:
    return
  var body: JsonNode
  try:
    body = bodyJson(request)
  except ValueError:
    releaseIdempotencyKey(user.id, ctx.communityId, key, resource)
    problem(request, 400, "INVALID_BODY", "body must be JSON")
    return
  let result = sessionSwap.swapMembers(application.db, ctx.communityId,
    sessionId, version.get, sessionSwap.parseSwap(body))
  case result.status
  of sessionSwap.swOk:
    let record = %*{"version": result.version, "status": result.sessionStatus}
    audit("session.swap", ctx, user, "session", sessionId,
      record)
    if key.len > 0:
      complete(application.db, user.id,
        idempotencyKey(ctx.communityId, key, resource), 200, record)
    application.hub.sessionChanged(sessionId, result.version)
    jsonResponse(request, 200, record,
      [("ETag", "\"" & $result.version & "\""),
       ("Cache-Control", "no-store")])
  of sessionSwap.swInvalid:
    releaseIdempotencyKey(user.id, ctx.communityId, key, resource)
    problem(request, 400, "INVALID_SWAP", result.detail)
  of sessionSwap.swStale:
    releaseIdempotencyKey(user.id, ctx.communityId, key, resource)
    problem(request, 412, "STALE_VERSION", "session changed since If-Match")
  of sessionSwap.swNotFound:
    releaseIdempotencyKey(user.id, ctx.communityId, key, resource)
    problem(request, 404, "NOT_FOUND", "session not found")
  of sessionSwap.swLocked:
    releaseIdempotencyKey(user.id, ctx.communityId, key, resource)
    problem(request, 403, "FORBIDDEN", "session is locked")

proc ratingParamsFor(ctx: CommunityContext): ratingDomain.RatingParams =
  ratingParams.loadRatingParams(configSnapshot(),
    currentSettings(application.db, ctx.communityId))

proc reconcileAchievements(ctx: CommunityContext,
                           params: ratingDomain.RatingParams) =
  ## Badges are derived from the same sessions and tournaments the board reads,
  ## so every path that moves the rating reconciles the shelf too: a reverted
  ## result must take its badge with it. The board anchor is read the way the
  ## CLI tick reads it.
  discard achievementBackfill.backfill(application.db, ctx.communityId,
    ratingRead.latestEventDate(application.db, ctx.communityId), params)

proc setSessionLock(request: Request, ctx: CommunityContext, user: AuthUser,
                    sessionId: string, locked: bool) =
  let version = requireIfMatch(request)
  if version.isNone: return
  # A sign-off freezes the source: unlocking withdraws its event, and re-locking
  # used to rewrite `approved_at`/`approved_by`, so a host could re-stamp a
  # result an admin had approved. Both directions refuse now.
  if ratingIngest.sourceFinalized(application.db, ctx.communityId, sessionId):
    problem(request, 403, "FORBIDDEN", "rating source is finalized")
    return
  let result = sessionWrite.setLock(application.db, ctx.communityId, sessionId,
    user.id, version.get, locked)
  case result.status
  of wsOk:
    # Approval is the rating gate: locking rates the session now, unlocking
    # withdraws what it contributed. Without this the ledger keeps points from
    # a session that is no longer approved.
    let params = ratingParamsFor(ctx)
    if locked:
      discard ratingIngest.ingestSession(application.db, ctx.communityId,
        sessionId, params)
    else:
      let removed = ratingIngest.revertSource(application.db, ctx.communityId,
        sessionId)
      if removed > 0:
        discard ratingIngest.rebuild(application.db, ctx.communityId, params)
    reconcileAchievements(ctx, params)
    audit(if locked: "session.lock" else: "session.unlock", ctx, user,
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
    "values": visibleSettings(settings),
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
    user.id, body, uuidv7(), $ctx.role)
  case result.outcome
  of soOk:
    jsonResponse(request, 200,
      %*{"values": visibleSettings(currentSettings(application.db,
        ctx.communityId))},
      [("Cache-Control", "no-store")])
  of soUnknownKey:
    problem(request, 400, "UNKNOWN_CONFIG_KEY", result.detail & ": " & result.key)
  of soPlatformScope:
    problem(request, 400, "PLATFORM_CONFIG_KEY", result.detail & ": " & result.key)
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
  let ttl = configSnapshot().intValue(
    currentSettings(application.db, ctx.communityId), keyCommunityInviteTtlDays)
  let token = inviteStore.create(application.db, ctx.communityId,
    sha256Hex(email.strip().toLowerAscii()), $parsed, user.id, ttl)
  audit("community.invite", ctx, user, "community", ctx.communityId,
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
      result.communityId, %*{"role": result.role}, result.role)
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
  if user.isSome:
    # Per account per window: a repeated submission is a script, not a person,
    # and the anonymous path never reaches the store anyway.
    let rate = configSnapshot().intValue(%*{}, keySecurityJoinRequestRate)
    let budget = application.limiter.hit("join|" & requestIdentity(request),
      rate, epochTime())
    if not budget.allowed:
      rateLimited(request, budget)
      return
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
  case membershipStore.setRoleChecked(application.db, ctx.communityId,
      targetId, role)
  of membershipStore.mwLastAdmin:
    problem(request, 409, "LAST_ADMIN", "promote another admin first")
    return
  of membershipStore.mwNotFound:
    problem(request, 404, "NOT_FOUND", "member not found")
    return
  of membershipStore.mwOk:
    discard
  audit("community.member.role", ctx, user, "user", targetId,
    %*{"role": role})
  jsonResponse(request, 200, %*{"userId": targetId, "role": role})

proc removeMember(request: Request, ctx: CommunityContext, user: AuthUser,
                  targetId: string) =
  case membershipStore.removeChecked(application.db, ctx.communityId, targetId)
  of membershipStore.mwLastAdmin:
    problem(request, 409, "LAST_ADMIN", "promote another admin first")
    return
  of membershipStore.mwNotFound:
    problem(request, 404, "NOT_FOUND", "member not found")
    return
  of membershipStore.mwOk:
    discard
  # A removed member loses the sockets and tickets of that principal.
  application.hub.revokePrincipal(targetId)
  audit("community.member.remove", ctx, user, "user", targetId)
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
    audit("player.create", ctx, user, "player", playerId,
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
    if result.aliasTaken:
      problem(request, 409, "ALIAS_TAKEN", "an alias is already used by another player")
      return
    audit("player.patch", ctx, user, "player", playerId,
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
    audit("player.merge", ctx, user, "player", targetId,
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
  audit("player.delete", ctx, user, "player", playerId)
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

proc listClaimsRoute(request: Request, ctx: CommunityContext, user: AuthUser,
                     playerId: string) =
  ## Members see the claim trail but not who else applied or who decided:
  ## only a member's own claim stays identifiable, so the page can still say
  ## they are waiting. Hosts and admins need the full record to act on it.
  if playerStore.get(application.db, ctx.communityId, playerId).isNone:
    problem(request, 404, "NOT_FOUND", "player not found")
    return
  let privileged = ctx.role in [rHost, rAdmin]
  var items = newJArray()
  for claim in playerClaim.list(application.db, ctx.communityId, playerId):
    let reveal = privileged or claim.userId == user.id
    items.add(%*{
      "id": claim.id,
      "userId": (if reveal: claim.userId else: ""),
      "status": claim.status,
      "decidedBy": (if reveal: claim.decidedBy else: ""),
      "decidedAt": (if reveal: claim.decidedAt else: ""),
      "reason": (if reveal: claim.reason else: ""),
      "createdAt": claim.createdAt,
    })
  jsonResponse(request, 200, %*{"items": items}, [("Cache-Control", "no-store")])

proc submitClaim(request: Request, ctx: CommunityContext, user: AuthUser,
                 playerId: string) =
  let result = playerClaim.submit(application.db, ctx.communityId, playerId, user.id)
  if result != ceOk:
    claimProblem(request, result)
    return
  audit("player.claim.submitted", ctx, user, "player", playerId)
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
    audit("player.claim.released", ctx, user, "claim", claimId,
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
  audit("player.claim.released", ctx, user, "claim", claimId,
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

const
  ## The per-code ceiling is the per-viewer one times this factor: everyone
  ## watching the same link shares one budget instead of competing for it.
  shareGlobalFactor = 10

const requiredRelations = [
  # One name per area the process cannot work without. `to_regclass` answers
  # without touching the tables, so readiness never becomes a write path.
  "platform.community", "platform.user", "platform.config",
  "platform.cutover_state", "community.membership", "player.players",
  "session.sessions", "session.games", "rating.events",
  "rating.player_state", "auth.oauth_flows", "account.audit",
  "dbtools.schema_migrations"]

proc readyz(request: Request) =
  ## Readiness answers "can this process serve traffic against this database":
  ## reachable, migrated, and holding the snapshot the operator expects. A
  ## process pointed at the wrong dump must not take traffic, so a recorded
  ## snapshot that disagrees with CUTOVER_SNAPSHOT_SHA256 is a refusal.
  var detail = ""
  try:
    let missing = application.db.queryOne(
      """select count(*)::int as missing
         from unnest($1::text[]) as wanted(name)
         where to_regclass(wanted.name) is null""",
      @[textParam("{" & requiredRelations.join(",") & "}")])
    if parseInt(missing.get.get("missing")) > 0:
      detail = "schema is not migrated"
  except DbError:
    detail = "database is unreachable"

  if detail.len == 0:
    let expected = getEnv("CUTOVER_SNAPSHOT_SHA256")
    try:
      let row = application.db.queryOne(
        "select snapshot_sha256 from platform.cutover_state where id")
      if row.isSome and expected.len > 0:
        let recorded = row.get["snapshot_sha256"]
        if recorded.isSome and recorded.get.len > 0 and recorded.get != expected:
          detail = "database holds a different snapshot"
    except DbError:
      detail = "database is unreachable"

  if detail.len == 0:
    send(request, 200, """{"status":"ok"}""")
  else:
    jsonResponse(request, 503, %*{"status": 503, "code": "NOT_READY",
      "detail": detail}, [("Cache-Control", "no-store")])

proc sessionVersionNow(communityId, sessionId: string): int =
  let row = application.db.queryOne(
    """select version from session.sessions
       where community_id = $1::uuid and id = $2::uuid""",
    @[textParam(communityId), textParam(sessionId)])
  if row.isSome: parseInt(row.get.get("version")) else: 0

proc ingestSessionRating(request: Request, ctx: CommunityContext,
                         user: AuthUser, sessionId: string) =
  ## A session id that names nothing in this community is a 404, not a silent
  ## ingest of zero rows that the caller cannot tell apart from a no-op.
  if sessionVersionNow(ctx.communityId, sessionId) == 0:
    problem(request, 404, "NOT_FOUND", "session not found")
    return
  let params = ratingParamsFor(ctx)
  let result = ratingIngest.ingestSession(application.db, ctx.communityId,
    sessionId, params)
  reconcileAchievements(ctx, params)
  audit("rating.session.ingest", ctx, user, "session", sessionId,
    %*{"events": result.events, "deltas": result.deltas})
  jsonResponse(request, 200, %*{"events": result.events,
    "deltas": result.deltas}, [("Cache-Control", "no-store")])

proc sessionApproved(communityId, sessionId: string): bool =
  let row = application.db.queryOne(
    """select 1 as ok from session.sessions
       where community_id = $1::uuid and id = $2::uuid
         and approved_at is not null""",
    @[textParam(communityId), textParam(sessionId)])
  row.isSome

proc clearSessionRating(request: Request, ctx: CommunityContext,
                        user: AuthUser, sessionId: string) =
  if sessionVersionNow(ctx.communityId, sessionId) == 0:
    problem(request, 404, "NOT_FOUND", "session not found")
    return
  if ratingIngest.sourceFinalized(application.db, ctx.communityId, sessionId):
    problem(request, 403, "FORBIDDEN", "rating source is finalized")
    return
  # The rebuild replays every approved session, so deleting the event of a
  # session that is still approved only changes its id: the points come straight
  # back and `removedDeltas` would be a lie. Withdraw the approval first.
  if sessionApproved(ctx.communityId, sessionId):
    problem(request, 409, "CONFLICT",
      "session is still approved; unlock it first")
    return
  let params = ratingParamsFor(ctx)
  let removed = ratingIngest.revertSource(application.db, ctx.communityId, sessionId)
  var rebuilt = ratingIngest.IngestResult()
  if removed > 0:
    rebuilt = ratingIngest.rebuild(application.db, ctx.communityId, params)
    reconcileAchievements(ctx, params)
  audit("rating.session.revert", ctx, user, "session", sessionId,
    %*{"removedDeltas": removed})
  jsonResponse(request, 200, %*{"removedDeltas": removed,
    "events": rebuilt.events, "deltas": rebuilt.deltas},
    [("Cache-Control", "no-store")])

proc rebuildRatings(request: Request, ctx: CommunityContext,
                    user: AuthUser) =
  let params = ratingParamsFor(ctx)
  let result = ratingIngest.rebuild(application.db, ctx.communityId, params)
  reconcileAchievements(ctx, params)
  audit("rating.rebuild", ctx, user, "community", ctx.communityId,
    %*{"events": result.events, "deltas": result.deltas})
  jsonResponse(request, 200, %*{"events": result.events,
    "deltas": result.deltas}, [("Cache-Control", "no-store")])

proc listRatingSources(request: Request, ctx: CommunityContext) =
  var items = newJArray()
  for row in application.db.query(
    """select e.id, e.event_type, e.local_date::text as local_date,
              coalesce(e.source_id::text, '') as source_id,
              coalesce(s.finalized, false) as finalized,
              s.finalized_at::text as finalized_at,
              e.point_entries::int as deltas
       from rating.events e
       left join rating.sources s
         on s.community_id = e.community_id and s.source_id = e.source_id
       where e.community_id = $1::uuid
       order by e.local_date desc, e.created_at desc""",
    @[textParam(ctx.communityId)]):
    items.add(%*{"id": row.get("id"), "type": row.get("event_type"),
      "date": row.get("local_date"), "sourceId": row.get("source_id"),
      "deltas": parseInt(row.get("deltas")),
      "finalized": row.get("finalized") == "t",
      "finalizedAt": if row["finalized_at"].isSome:
        %row.get("finalized_at") else: newJNull()})
  # A tournament that was never ingested has no event row, so a list built from
  # events would hide it from the admin who has to sign it off.
  for row in application.db.query(
    """select t.id, t.event_date::text as local_date,
              coalesce(s.finalized, false) as finalized,
              s.finalized_at::text as finalized_at
       from tournament.tournaments t
       left join rating.sources s
         on s.community_id = t.community_id and s.source_id = t.id
       where t.community_id = $1::uuid
         and not exists (
           select 1 from rating.events e
           where e.community_id = t.community_id
             and e.event_type = 'tournament' and e.source_id = t.id)
       order by t.event_date desc""",
    @[textParam(ctx.communityId)]):
    items.add(%*{"id": row.get("id"), "type": "tournament",
      "date": row.get("local_date"), "sourceId": row.get("id"),
      "deltas": 0,
      "finalized": row.get("finalized") == "t",
      "finalizedAt": if row["finalized_at"].isSome:
        %row.get("finalized_at") else: newJNull()})
  jsonResponse(request, 200, %*{"items": items}, [("Cache-Control", "no-store")])

proc removeRatingSource(request: Request, ctx: CommunityContext, user: AuthUser,
                        eventId: string) =
  ## An id that names no event is a 404, not a silent success: the caller is
  ## asking to undo something, and "there was nothing there" is the answer.
  let known = application.db.queryOne(
    """select 1 as ok from rating.events
       where community_id = $1::uuid and id = $2::uuid""",
    @[textParam(ctx.communityId), textParam(eventId)])
  if known.isNone:
    problem(request, 404, "NOT_FOUND", "rating event not found")
    return
  if ratingIngest.eventFinalized(application.db, ctx.communityId, eventId):
    problem(request, 403, "FORBIDDEN", "rating source is finalized")
    return
  let event = application.db.queryOne(
    """select event_type, source_id::text as source_id from rating.events
       where community_id = $1::uuid and id = $2::uuid""",
    @[textParam(ctx.communityId), textParam(eventId)])
  if event.isSome and event.get.get("event_type") == "session" and
      sessionApproved(ctx.communityId, event.get.get("source_id")):
    problem(request, 409, "CONFLICT",
      "session is still approved; unlock it first")
    return
  let params = ratingParamsFor(ctx)
  let removed = ratingIngest.removeEvent(application.db, ctx.communityId, eventId)
  let rebuilt = ratingIngest.rebuild(application.db, ctx.communityId, params)
  reconcileAchievements(ctx, params)
  audit("rating.source.delete", ctx, user, "rating_event", eventId,
    %*{"removedDeltas": removed})
  jsonResponse(request, 200, %*{"removedDeltas": removed,
    "events": rebuilt.events, "deltas": rebuilt.deltas},
    [("Cache-Control", "no-store")])

proc deleteSession(request: Request, ctx: CommunityContext, user: AuthUser,
                   sessionId: string) =
  ## Drafts are deletable by the session's host, any status by an admin. The
  ## rating event that named this session goes with it, then the derived state
  ## is rebuilt so the board cannot keep points from a deleted session. A
  ## signed-off source must be reverted first: deleting it would erase a
  ## decision the ledger is supposed to keep.
  if ratingIngest.sourceFinalized(application.db, ctx.communityId, sessionId):
    problem(request, 403, "FORBIDDEN", "rating source is finalized")
    return
  # The links go with the session, so their watchers have to be told before the
  # rows they point at are gone.
  let links = shareStore.liveLinks(application.db, ctx.communityId, sessionId)
  # Params are read before the transaction: the config and settings lookups use
  # the pool, and a nested acquisition inside a held connection would wait on
  # the pool instead of this transaction.
  let params = ratingParamsFor(ctx)
  # Delete, revert and rebuild in one transaction: a failure halfway must leave
  # the session and its derived points as they were, not a deleted session with
  # a stale board and a 500.
  var outcome = sessionWrite.dsDeleted
  var removed = 0
  discard application.db.tx(proc(conn: DbConn): int =
    outcome = sessionWrite.removeConn(conn, ctx.communityId, sessionId,
      ctx.role == rAdmin)
    if outcome == sessionWrite.dsDeleted:
      removed = ratingIngest.revertSourceConn(conn, ctx.communityId, sessionId)
      if removed > 0:
        discard ratingIngest.rebuildConn(conn, ctx.communityId, params)
      discard ratingIngest.dropSourceConn(conn, ctx.communityId, sessionId)
    1)
  case outcome
  of sessionWrite.dsNotFound:
    problem(request, 404, "NOT_FOUND", "session not found")
    return
  of sessionWrite.dsNotDraft:
    problem(request, 403, "FORBIDDEN", "only an admin can delete this session")
    return
  of sessionWrite.dsDeleted:
    reconcileAchievements(ctx, params)
  for linkId in links:
    application.hub.revokeShare(linkId)
  audit("session.delete", ctx, user, "session", sessionId,
    %*{"removedDeltas": removed})
  send(request, 204, @[("Cache-Control", "no-store")], "")

proc patchRatingSource(request: Request, ctx: CommunityContext, user: AuthUser,
                       eventId: string) =
  var body: JsonNode
  try:
    body = bodyJson(request)
  except ValueError:
    problem(request, 400, "INVALID_BODY", "body must be JSON")
    return
  if body.kind != JObject or not body.hasKey("finalized") or
     body["finalized"].kind != JBool:
    problem(request, 400, "INVALID_BODY", "finalized must be a boolean")
    return
  let finalized = body["finalized"].getBool()
  if finalized:
    # A session is only signable once it has a rating. Accepting a draft with
    # no event recorded a flag the ledger never shows, which then blocked the
    # delete and let a later lock create the result under that sign-off.
    let isSession = application.db.queryOne(
      """select 1 as ok from session.sessions
         where community_id = $1::uuid and id = $2::uuid""",
      @[textParam(ctx.communityId), textParam(eventId)]).isSome
    if isSession and application.db.queryOne(
        """select 1 as ok from rating.events
           where community_id = $1::uuid and source_id = $2::uuid""",
        @[textParam(ctx.communityId), textParam(eventId)]).isNone:
      problem(request, 409, "NOT_RATED", "session has no rating to sign off")
      return
  # Resolve the current flag first: only a source that is being signed off
  # again (not an idempotent repeat) needs its event replayed.
  let alreadyFinalized = application.db.queryOne(
    """select 1 as ok from rating.sources s
       where s.community_id = $1::uuid and s.finalized
         and (s.source_id = $2::uuid
              or s.source_id = (select e.source_id from rating.events e
                                where e.community_id = $1::uuid
                                  and e.id = $2::uuid))""",
    @[textParam(ctx.communityId), textParam(eventId)]).isSome
  let updated = ratingIngest.setFinalized(application.db, ctx.communityId,
    eventId, finalized)
  if updated.isNone:
    problem(request, 404, "NOT_FOUND", "rating source not found")
    return
  if finalized and not alreadyFinalized and
      updated.get["kind"].getStr() == "tournament":
    let sourceId = updated.get["sourceId"].getStr()
    let ingested = application.db.queryOne(
      """select 1 as ok from rating.events
         where community_id = $1::uuid and source_id = $2::uuid""",
      @[textParam(ctx.communityId), textParam(sourceId)])
    if ingested.isSome:
      # The bracket may have been edited between withdrawing and restoring the
      # sign-off. The stored event still carries the old scores, so replay every
      # source instead of leaving the ledger on a stale result.
      let params = ratingParamsFor(ctx)
      discard ratingIngest.rebuild(application.db, ctx.communityId, params)
      reconcileAchievements(ctx, params)
  audit("rating.source.finalize", ctx, user, "rating_event",
    eventId, %*{"finalized": finalized})
  jsonResponse(request, 200, updated.get, [("Cache-Control", "no-store")])

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
  of sessionSchedule.ssLocked:
    problem(request, 403, "FORBIDDEN", "session is locked")
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
  if body.hasKey("played"):
    if body["played"].kind != JBool:
      problem(request, 400, "INVALID_BODY", "played must be a boolean")
      return
    scheduleDone(request, ctx, sessionId,
      sessionSchedule.setPlayed(application.db, ctx.communityId, sessionId,
        gameKey, version.get, body["played"].getBool()))
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
  var body: JsonNode
  try:
    body = bodyJson(request)
  except ValueError:
    problem(request, 400, "INVALID_BODY", "body must be JSON")
    return
  if body.kind == JObject and body.hasKey("playerIds"):
    if body["playerIds"].kind != JArray:
      problem(request, 400, "INVALID_SCHEDULE", "playerIds must be an array")
      return
    var playerIds: seq[string] = @[]
    for item in body["playerIds"]:
      if item.kind != JString:
        problem(request, 400, "INVALID_SCHEDULE",
          "playerIds must hold strings")
        return
      playerIds.add(item.getStr())
    scheduleDone(request, ctx, sessionId,
      sessionSchedule.setSkips(application.db, ctx.communityId, sessionId,
        gameKey, version.get, playerIds))
    return
  scheduleDone(request, ctx, sessionId,
    sessionSchedule.skipGame(application.db, ctx.communityId, sessionId, gameKey,
      version.get))

proc getSessionStandingsRoute(request: Request, ctx: CommunityContext,
                              sessionId: string) =
  ## Members read the same board the export draws; an unknown or foreign
  ## session is a 404, never an empty board.
  let board = sessionStandings.compute(application.db, ctx.communityId, sessionId)
  if board.isNone:
    problem(request, 404, "NOT_FOUND", "session not found")
    return
  jsonResponse(request, 200, board.get, [("Cache-Control", "no-store")])

proc getSessionDetail(request: Request, ctx: CommunityContext,
                      sessionId: string) =
  ## The whole session in one read: header, who is playing and the games. The
  ## schedule has a write endpoint but no read of its own, and a page cannot
  ## render games it has no keys for.
  let row = application.db.queryOne(
    """select id, title, session_date::text as session_date,
              to_char(start_time, 'HH24:MI') as start_time, slot_minutes,
              status, version
       from session.sessions where id = $1 and community_id = $2""",
    @[textParam(sessionId), textParam(ctx.communityId)])
  if row.isNone:
    problem(request, 404, "NOT_FOUND", "session not found")
    return
  let etag = "\"" & row.get.get("version") & "\""
  # A poll that already has this version costs a 304 instead of the full read.
  if ifNoneMatchHits(request, etag):
    send(request, 304, @[("ETag", etag), ("Cache-Control", "no-store")], "")
    return
  var participants = newJArray()
  for entry in application.db.query(
    """select p.player_id, pl.canonical_name as name, p.is_absent
       from session.participants p
       join player.players pl on pl.id = p.player_id
       where p.community_id = $1::uuid and p.session_id = $2::uuid
       order by pl.canonical_name""",
    @[textParam(ctx.communityId), textParam(sessionId)]):
    participants.add(%*{"playerId": entry.get("player_id"),
      "name": entry.get("name"), "absent": entry.get("is_absent") == "t"})
  var games = newJArray()
  for entry in application.db.query(
    """select round_no, court_no, score_a, score_b, status,
              coalesce(side_a1::text, '') as side_a1,
              coalesce(side_a2::text, '') as side_a2,
              coalesce(side_b1::text, '') as side_b1,
              coalesce(side_b2::text, '') as side_b2
       from session.games
       where community_id = $1::uuid and session_id = $2::uuid
       order by round_no, court_no""",
    @[textParam(ctx.communityId), textParam(sessionId)]):
    var sideA = newJArray()
    var sideB = newJArray()
    for slot in ["side_a1", "side_a2"]:
      if entry.get(slot).len > 0: sideA.add(%entry.get(slot))
    for slot in ["side_b1", "side_b2"]:
      if entry.get(slot).len > 0: sideB.add(%entry.get(slot))
    games.add(%*{
      "round": parseInt(entry.get("round_no")),
      "court": parseInt(entry.get("court_no")),
      "sideA": sideA, "sideB": sideB,
      "scoreA": if entry["score_a"].isNone: newJNull() else: %parseInt(entry.get("score_a")),
      "scoreB": if entry["score_b"].isNone: newJNull() else: %parseInt(entry.get("score_b")),
      "status": entry.get("status")})
  var skipped = newJObject()
  for entry in application.db.query(
    """select round_no, court_no, player_id::text as player_id
       from session.game_skips
       where community_id = $1::uuid and session_id = $2::uuid
       order by round_no, court_no, player_id""",
    @[textParam(ctx.communityId), textParam(sessionId)]):
    let gameKey = entry.get("round_no") & "-" & entry.get("court_no")
    if not skipped.hasKey(gameKey):
      skipped[gameKey] = newJArray()
    skipped[gameKey].add(%entry.get("player_id"))
  jsonResponse(request, 200, %*{
    "id": row.get.get("id"),
    "title": row.get.get("title"),
    "date": row.get.get("session_date"),
    "startTime": row.get.get("start_time"),
    "slotMinutes": parseInt(row.get.get("slot_minutes")),
    "status": row.get.get("status"),
    "version": parseInt(row.get.get("version")),
    "participants": participants,
    "games": games,
    "skippedPlayers": skipped},
    [("ETag", etag),
     ("Cache-Control", "no-store")])

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
  audit("share.redisplay", ctx, user, "session", sessionId,
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
    """select g.id, g.round_no, g.court_no, g.score_a, g.score_b, g.status,
              coalesce(a1.canonical_name, '') as a1,
              coalesce(a2.canonical_name, '') as a2,
              coalesce(b1.canonical_name, '') as b1,
              coalesce(b2.canonical_name, '') as b2
       from session.games g
       left join player.players a1 on a1.id = g.side_a1
       left join player.players a2 on a2.id = g.side_a2
       left join player.players b1 on b1.id = g.side_b1
       left join player.players b2 on b2.id = g.side_b2
       where g.community_id = $1::uuid and g.session_id = $2::uuid
       order by g.round_no, g.court_no""",
    @[textParam(value.communityId), textParam(value.sessionId)]):
    # Names, not ids: a spectator cannot resolve a uuid, and the share payload
    # is the only read that has no session behind it.
    var sideA = newJArray()
    var sideB = newJArray()
    for slot in ["a1", "a2"]:
      if row.get(slot).len > 0: sideA.add(%row.get(slot))
    for slot in ["b1", "b2"]:
      if row.get(slot).len > 0: sideB.add(%row.get(slot))
    games.add(%*{
      "id": row.get("id"),
      "round": parseInt(row.get("round_no")),
      "court": parseInt(row.get("court_no")),
      "sideA": sideA, "sideB": sideB,
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

proc optInt(value: Option[int]): JsonNode =
  if value.isSome: %value.get else: newJNull()

proc breakdownJson(entries: seq[ratingRead.BreakdownEntry]): JsonNode =
  var items = newJArray()
  for entry in entries:
    items.add(%*{
      "sourceId": if entry.sourceId.isSome: %entry.sourceId.get else: newJNull(),
      "date": entry.date,
      "kind": entry.kind,
      "points": entry.points,
      "games": entry.games})
  items

proc boardRowJson(rank: int, row: ratingRead.BoardRow): JsonNode =
  ## The rank is positional, so the caller passes it; every other field comes
  ## from the same board read.
  %*{"rank": rank, "playerId": row.playerId, "name": row.name,
    "tier": if row.tier.len == 0: newJNull() else: %row.tier,
    "points": row.points, "games": row.games, "wins": row.wins,
    "losses": row.losses,
    "prevRank": optInt(row.prevRank),
    "rankDelta": optInt(row.rankDelta),
    "countedEntries": row.countedEntries,
    "entriesAvailable": row.entriesAvailable,
    "thinEvidence": row.thinEvidence,
    "breakdown": breakdownJson(row.breakdown)}

proc boardItems(rows: seq[ratingRead.BoardRow]): JsonNode =
  var items = newJArray()
  for row in rows:
    items.add(boardRowJson(row.rank, row))
  items

proc minSessionsParam(request: Request, fallback: int): int =
  ## `rank.min_sessions` is the default (seeded 0, the v1 filter); an explicit
  ## query parameter overrides it. A malformed value falls back to the default
  ## instead of failing the read.
  let raw = request.queryParams["min_sessions"]
  if raw.len == 0:
    return max(fallback, 0)
  try:
    max(parseInt(raw), 0)
  except ValueError:
    max(fallback, 0)

proc communityBoard(request: Request, communityId, timezone: string,
                    playerIds: seq[string] = @[]) =
  ## The member page reads the whole community board; a share link passes the
  ## session's participants so the public copy is one session, not the ladder.
  let settings = currentSettings(application.db, communityId)
  let snapshot = configSnapshot()
  let params = ratingParams.loadRatingParams(snapshot, settings)
  let limit = snapshot.intValue(settings, keyRankBoardLimit)
  let minSessions = minSessionsParam(request,
    snapshot.intValue(settings, keyRankMinSessions))
  let latest = ratingRead.latestEventDate(application.db, communityId)
  let asOf = if latest.len > 0: latest else: communityToday(timezone)
  let query = ratingRead.BoardQuery(communityId: communityId,
    asOf: asOf, params: params, limit: limit,
    tier: request.queryParams["tier"], minSessions: minSessions,
    playerIds: playerIds)
  let rows = ratingRead.board(application.db, query)
  jsonResponse(request, 200, %*{"items": boardItems(rows),
    "asOf": asOf,
    "windowWeeks": params.windowWeeks, "bestN": params.bestN,
    "minSessions": minSessions}, [("Cache-Control", "no-store")])

proc rankingPlayer(request: Request, communityId, timezone, playerId: string,
                   playerIds: seq[string] = @[]) =
  let settings = currentSettings(application.db, communityId)
  let params = ratingParams.loadRatingParams(configSnapshot(), settings)
  let limit = configSnapshot().intValue(settings, keyRankBoardLimit)
  let latest = ratingRead.latestEventDate(application.db, communityId)
  let asOf = if latest.len > 0: latest else: communityToday(timezone)
  let query = ratingRead.BoardQuery(communityId: communityId,
    asOf: asOf, params: params, limit: limit, tier: "",
    playerIds: playerIds)
  let rows = ratingRead.board(application.db, query)
  var found = false
  var item: JsonNode
  for row in rows:
    if row.playerId == playerId:
      item = boardRowJson(row.rank, row)
      found = true
      break
  if not found:
    problem(request, 404, "NOT_FOUND", "player is not on the board")
    return
  # The v1 detail view explained why a player could be missing, so it got the
  # same window numbers as the board.
  item["windowWeeks"] = %params.windowWeeks
  item["bestN"] = %params.bestN
  item["minSessions"] = %params.thinEvidenceN
  jsonResponse(request, 200, item, [("Cache-Control", "no-store")])

proc playerAchievements(request: Request, ctx: CommunityContext,
                        playerId: string) =
  if playerStore.get(application.db, ctx.communityId, playerId).isNone:
    problem(request, 404, "NOT_FOUND", "player not found")
    return
  let items = achievementBackfill.listForPlayer(application.db,
    ctx.communityId, playerId)
  var body = newJArray()
  for item in items:
    body.add(item)
  jsonResponse(request, 200, %*{"items": body}, [("Cache-Control", "no-store")])

proc boardPoints(communityId, timezone, playerId: string): int =
  ## The one points number the API exposes: the player's row on today's board,
  ## resolved the same way the leaderboard resolves it. A player with no entry
  ## in the window has no row, so the page shows zero instead of a career total
  ## no board ever displayed.
  let settings = currentSettings(application.db, communityId)
  let params = ratingParams.loadRatingParams(configSnapshot(), settings)
  let limit = configSnapshot().intValue(settings, keyRankBoardLimit)
  let latest = ratingRead.latestEventDate(application.db, communityId)
  let asOf = if latest.len > 0: latest else: communityToday(timezone)
  let row = ratingRead.boardEntry(application.db, ratingRead.BoardQuery(
    communityId: communityId, asOf: asOf, params: params, limit: limit,
    tier: ""), playerId)
  if row.isSome: row.get.points else: 0

proc playerStats(request: Request, ctx: CommunityContext, playerId: string) =
  let found = ratingRead.stats(application.db, ctx.communityId, playerId)
  if found.isNone:
    problem(request, 404, "NOT_FOUND", "player not found")
    return
  var body = found.get
  body["points"] = %boardPoints(ctx.communityId, ctx.timezone, playerId)
  jsonResponse(request, 200, body, [("Cache-Control", "no-store")])

proc sessionPlayerIds(communityId, sessionId: string): seq[string] =
  ## The players who took part in one session. A share code opens that session,
  ## so the public board it serves is this set and never the whole community.
  for row in application.db.query(
    """select player_id from session.participants
       where community_id = $1::uuid and session_id = $2::uuid""",
    @[textParam(communityId), textParam(sessionId)]):
    result.add(row.get("player_id"))

proc getSharedRanking(request: Request, code, playerId: string) =
  ## The share code names one session, so the public detail is that player's row
  ## on the shared board. Anyone who did not play in the session is a 404, even
  ## if they sit high on the community ladder.
  let found = shareStore.resolve(application.db, application.keyring, code)
  if found.isNone:
    problem(request, 404, "NOT_FOUND", "link not found")
    return
  let playerIds = sessionPlayerIds(found.get.communityId, found.get.sessionId)
  if playerId notin playerIds:
    problem(request, 404, "NOT_FOUND", "player is not on the board")
    return
  rankingPlayer(request, found.get.communityId, found.get.timezone, playerId,
    playerIds)

proc getSharedRankings(request: Request, code: string) =
  let found = shareStore.resolve(application.db, application.keyring, code)
  if found.isNone:
    problem(request, 404, "NOT_FOUND", "link not found")
    return
  communityBoard(request, found.get.communityId, found.get.timezone,
    sessionPlayerIds(found.get.communityId, found.get.sessionId))

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
  # The per-address watcher cap would become a platform-wide cap behind the CDN
  # edge, so a signed-in watcher is bucketed by user id. Shared links have no
  # user, and their per-channel cap already applies.
  let watcherBucket =
    if userId.len > 0: "user:" & userId
    else: clientAddress
  if not application.hub.admit(socket, kind & ":" & channelId, userId,
      watcherBucket, caps):
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

proc sendSnapshot(request: Request, status: int, snapshot: JsonNode,
                  extra: openArray[(string, string)] = []) =
  var headers = @[("Cache-Control", "no-store")]
  if snapshot.hasKey("version"):
    headers.add(("ETag", "\"" & $snapshot["version"].getInt() & "\""))
  for pair in extra:
    headers.add(pair)
  jsonResponse(request, status, snapshot, headers)

proc saveFailure(request: Request, status: tournamentStore.SaveStatus) =
  case status
  of tournamentStore.svOk:
    discard
  of tournamentStore.svNotFound:
    problem(request, 404, "NOT_FOUND", "tournament not found")
  of tournamentStore.svStale:
    problem(request, 412, "STALE_VERSION", "tournament changed since If-Match")
  of tournamentStore.svInvalid:
    problem(request, 400, "INVALID_TOURNAMENT", "tournament body is invalid")
  of tournamentStore.svLocked:
    problem(request, 403, "FORBIDDEN", "rating source is finalized")

proc listTournamentsRoute(request: Request, ctx: CommunityContext) =
  let limit = configSnapshot().intValue(%*{}, keyApiPageSizeDefault)
  var offset = 0
  let rawOffset = request.queryParams.getOrDefault("offset", "")
  if rawOffset.len > 0:
    try: offset = parseInt(rawOffset)
    except ValueError: offset = 0
  var items = newJArray()
  for item in tournamentStore.list(application.db, ctx.communityId,
      request.queryParams.getOrDefault("format", ""), limit, offset):
    items.add(item)
  jsonResponse(request, 200, %*{"items": items}, [("Cache-Control", "no-store")])

proc createTournamentRoute(request: Request, ctx: CommunityContext,
                           user: AuthUser) =
  let key = request.headers["Idempotency-Key"]
  if idempotentWrite(request, user.id, ctx.communityId, key,
      request.body).isSome:
    return
  var body: JsonNode
  try: body = bodyJson(request)
  except ValueError:
    problem(request, 400, "INVALID_BODY", "body must be JSON")
    return
  let (status, snapshot) = tournamentStore.create(application.db,
    ctx.communityId, user.id, body)
  if status == tournamentStore.svInvalid:
    releaseIdempotencyKey(user.id, ctx.communityId, key, "")
    jsonResponse(request, 400, snapshot)
    return
  if status != tournamentStore.svOk:
    releaseIdempotencyKey(user.id, ctx.communityId, key, "")
    saveFailure(request, status)
    return
  let id = snapshot["id"].getStr()
  let record = %*{"id": id, "version": snapshot["version"]}
  audit("tournament.create", ctx, user, "tournament", id, record)
  if key.len > 0:
    complete(application.db, user.id, scopedKey(ctx.communityId, key), 201,
      snapshot)
  sendSnapshot(request, 201, snapshot,
    [("Location", "/c/" & ctx.slug & "/tournaments/" & id)])

proc getTournamentRoute(request: Request, ctx: CommunityContext, id: string) =
  let snapshot = tournamentStore.load(application.db, ctx.communityId, id)
  if snapshot.isNone:
    problem(request, 404, "NOT_FOUND", "tournament not found")
    return
  sendSnapshot(request, 200, snapshot.get)

proc putTournamentRoute(request: Request, ctx: CommunityContext, user: AuthUser,
                        id: string) =
  let version = requireIfMatch(request)
  if version.isNone:
    return
  let key = request.headers["Idempotency-Key"]
  let resource = "tournament/" & id
  if idempotentWrite(request, user.id, ctx.communityId, key,
      request.body, resource).isSome:
    return
  var body: JsonNode
  try: body = bodyJson(request)
  except ValueError:
    problem(request, 400, "INVALID_BODY", "body must be JSON")
    return
  let (status, snapshot) = tournamentStore.replace(application.db,
    ctx.communityId, id, user.id, body, version.get)
  case status
  of tournamentStore.svOk:
    let record = %*{"id": id, "version": snapshot["version"]}
    audit("tournament.update", ctx, user, "tournament", id, record)
    if key.len > 0:
      complete(application.db, user.id,
        idempotencyKey(ctx.communityId, key, resource), 200, snapshot)
    sendSnapshot(request, 200, snapshot)
  of tournamentStore.svInvalid:
    releaseIdempotencyKey(user.id, ctx.communityId, key, resource)
    jsonResponse(request, 400, snapshot)
  else:
    releaseIdempotencyKey(user.id, ctx.communityId, key, resource)
    saveFailure(request, status)

proc ingestTournamentRating(request: Request, ctx: CommunityContext,
                           user: AuthUser, id: string) =
  ## Admin-only. The source must be signed off first, which is the v1 gate and
  ## the reason a running bracket cannot leak half a tournament into the board.
  let params = ratingParamsFor(ctx)
  let result = ratingTournament.ingestTournament(application.db,
    ctx.communityId, id, params)
  case result.status
  of ratingTournament.tisOk:
    reconcileAchievements(ctx, params)
    audit("rating.tournament.ingest", ctx, user, "tournament", id,
      %*{"events": result.events, "deltas": result.deltas})
    jsonResponse(request, 200, %*{"events": result.events,
      "deltas": result.deltas}, [("Cache-Control", "no-store")])
  of ratingTournament.tisNotFinal:
    problem(request, 400, "INVALID_STATE",
      "tournament must be finalized before rating")
  of ratingTournament.tisNotFound:
    problem(request, 404, "NOT_FOUND", "tournament not found")

proc clearTournamentRating(request: Request, ctx: CommunityContext,
                           user: AuthUser, id: string) =
  ## An id that names no tournament is a 404, like the session variant: the
  ## caller is asking to undo something, and "there was nothing there" is the
  ## answer. Only a known tournament reaches the rebuild.
  let known = application.db.queryOne(
    """select 1 as ok from tournament.tournaments
       where community_id = $1::uuid and id = $2::uuid""",
    @[textParam(ctx.communityId), textParam(id)])
  if known.isNone:
    problem(request, 404, "NOT_FOUND", "tournament not found")
    return
  if ratingIngest.sourceFinalized(application.db, ctx.communityId, id):
    problem(request, 403, "FORBIDDEN", "rating source is finalized")
    return
  let params = ratingParamsFor(ctx)
  let removed = ratingIngest.revertSource(application.db, ctx.communityId, id)
  discard ratingIngest.rebuild(application.db, ctx.communityId, params)
  reconcileAchievements(ctx, params)
  audit("rating.tournament.revert", ctx, user, "tournament", id,
    %*{"removedDeltas": removed})
  send(request, 204, @[("Cache-Control", "no-store")], "")

proc deleteTournamentRoute(request: Request, ctx: CommunityContext,
                           user: AuthUser, id: string) =
  ## The Idempotency-Key is accepted but not persisted: a repeated delete is
  ## already a 404, and a 204 must not carry a replay body. A signed-off source
  ## has to be reverted first: deleting it would erase a ledger decision.
  if ratingIngest.sourceFinalized(application.db, ctx.communityId, id):
    problem(request, 403, "FORBIDDEN", "rating source is finalized")
    return
  if not tournamentStore.remove(application.db, ctx.communityId, id):
    problem(request, 404, "NOT_FOUND", "tournament not found")
    return
  # The rating event named this tournament; deleting the tournament without it
  # would leave points on the board for a bracket that no longer exists.
  let removed = ratingIngest.revertSource(application.db, ctx.communityId, id)
  if removed > 0:
    let params = ratingParamsFor(ctx)
    discard ratingIngest.rebuild(application.db, ctx.communityId, params)
    reconcileAchievements(ctx, params)
  discard ratingIngest.dropSource(application.db, ctx.communityId, id)
  audit("tournament.delete", ctx, user, "tournament", id,
    %*{"id": id, "removedDeltas": removed})
  send(request, 204, @[("Cache-Control", "no-store")], "")

proc patchTournamentMatchRoute(request: Request, ctx: CommunityContext,
                               user: AuthUser, id, matchId: string) =
  let version = requireIfMatch(request)
  if version.isNone:
    return
  let key = request.headers["Idempotency-Key"]
  let resource = "tournament/" & id & "/match/" & matchId
  if idempotentWrite(request, user.id, ctx.communityId, key,
      request.body, resource).isSome:
    return
  var body: JsonNode
  try: body = bodyJson(request)
  except ValueError:
    problem(request, 400, "INVALID_BODY", "body must be JSON")
    return
  let (status, snapshot) = tournamentStore.patchMatch(application.db,
    ctx.communityId, id, matchId, body, version.get)
  case status
  of tournamentStore.ptOk:
    let record = %*{"id": id, "matchId": matchId,
      "version": snapshot["version"]}
    audit("tournament.match.patch", ctx, user, "tournament", id,
      record)
    if key.len > 0:
      complete(application.db, user.id,
        idempotencyKey(ctx.communityId, key, resource), 200, snapshot)
    sendSnapshot(request, 200, snapshot)
  of tournamentStore.ptInvalid:
    releaseIdempotencyKey(user.id, ctx.communityId, key, resource)
    jsonResponse(request, 400, snapshot)
  of tournamentStore.ptNotFound:
    releaseIdempotencyKey(user.id, ctx.communityId, key, resource)
    problem(request, 404, "NOT_FOUND", "tournament or match not found")
  of tournamentStore.ptStale:
    releaseIdempotencyKey(user.id, ctx.communityId, key, resource)
    problem(request, 412, "STALE_VERSION", "tournament changed since If-Match")
  of tournamentStore.ptLocked:
    releaseIdempotencyKey(user.id, ctx.communityId, key, resource)
    problem(request, 403, "FORBIDDEN", "rating source is finalized")

proc outdatedClient(request: Request): bool =
  ## A bundle built for a different major speaks a contract this server does not
  ## serve, so it is told to reload instead of failing one request at a time.
  ## No header (CLI, probes) and unparsable values pass: only a different major
  ## is evidence of a bundle that must be reloaded.
  ##
  ## The newer-than-server case is what a rollback looks like: the image went
  ## back, the tab is still running the newer bundle, and without this it would
  ## keep talking to a server that cannot answer it.
  let header = request.headers["X-API-Version"].strip()
  if header.len == 0:
    return false
  let client =
    try: parseInt(header.split('.')[0])
    except ValueError: return false
  let server =
    try: parseInt(appVersion.split('.')[0])
    except ValueError: return false
  client != server

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
    let identity = requestIdentity(request)
    let routeLabel = templateRoute(path)
    let budget = application.limiter.hit(routeLabel & "|" & identity,
      snapshot.intValue(%*{}, keySecurityRateLimitPerMinute), epochTime())
    if not budget.allowed:
      rateLimited(request, budget)
      return
    # Share links are limited per viewer, so one scraper cannot exhaust the
    # budget of the group that holds the link, and per code at a looser ceiling
    # so a pool of addresses still cannot replay a scraped code without bound.
    if path.startsWith("/s/"):
      let parts = path.split('/')
      if parts.len >= 3:
        let codeKey = sha256Hex(parts[2])[0 .. 15]
        let limit = snapshot.intValue(%*{}, keySecurityShareScrapeLimit)
        let now = epochTime()
        let global = application.limiter.hit("share|" & codeKey,
          limit * shareGlobalFactor, now)
        let viewer = application.limiter.hit("share|" & codeKey & "|" & identity,
          limit, now)
        let refused = if not global.allowed: global else: viewer
        if not refused.allowed:
          rateLimited(request, refused)
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
    if path == "/version":
      if verb == "GET":
        jsonResponse(request, 200, %*{"version": appVersion, "commit": appCommit},
          [("Cache-Control", "no-store")])
      else:
        problem(request, 405, "METHOD", "")
      return
    if path == "/readyz":
      readyz(request)
      return
    if outdatedClient(request):
      jsonResponse(request, 410, %*{
        "status": 410, "code": "CLIENT_OUTDATED",
        "detail": "this client speaks an older contract; reload the page",
      }, [("Cache-Control", "no-store")])
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
          listClaimsRoute(request, ctx.get, user.get, parts[4])
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
        if parts.len == 6 and parts[5] in ["ws-ticket", "standings"]: readAccess()
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
      if parts.len == 5 and verb == "DELETE":
        deleteSession(request, ctx.get, user.get, parts[4])
        return
      if parts.len == 6 and parts[5] == "standings" and verb == "GET":
        getSessionStandingsRoute(request, ctx.get, parts[4])
        return
      if parts.len == 5 and verb == "GET":
        getSessionDetail(request, ctx.get, parts[4])
        return
      if parts.len == 6 and parts[5] == "share":
        if verb == "POST":
          createShare(request, ctx.get, user.get, parts[4])
          return
        if verb == "GET":
          getShareLink(request, ctx.get, user.get, parts[4])
          return
        if verb == "DELETE":
          deleteShareLink(request, ctx.get, user.get, parts[4])
          return
      if parts.len == 6 and parts[5] == "swap" and verb == "POST":
        swapSession(request, ctx.get, user.get, parts[4])
        return
      if parts.len == 6 and parts[5] == "ws-ticket" and verb == "POST":
        issueSessionTicket(request, ctx.get, user.get, parts[4])
        return
      if parts.len == 6 and parts[5] == "rating":
        if verb in ["POST", "DELETE"]:
          let admin = adminGate(request, parts[2])
          if admin.isNone: return
          if verb == "POST":
            ingestSessionRating(request, admin.get[1], admin.get[0], parts[4])
          else:
            clearSessionRating(request, admin.get[1], admin.get[0], parts[4])
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
    # /c/{slug}/tournaments[/{id}[/matches/{matchId}]]
    if parts.len >= 4 and parts[1] == "c" and parts[3] == "tournaments":
      let user = currentUser(request)
      if user.isNone:
        problem(request, 401, "UNAUTHENTICATED", "login required")
        return
      # matrix.yaml: reads are member, every write is host/admin.
      let access = if verb == "GET": readAccess() else: writeAccess()
      let (decision, ctx) = decide(user.get,
        cookieValue(request, "majadu_session"), parts[2], access)
      if decision != gAllowed:
        respondGate(request, decision)
        return
      if parts.len == 4 and verb == "GET":
        listTournamentsRoute(request, ctx.get)
        return
      if parts.len == 4 and verb == "POST":
        createTournamentRoute(request, ctx.get, user.get)
        return
      if parts.len == 5 and verb == "GET":
        getTournamentRoute(request, ctx.get, parts[4])
        return
      if parts.len == 5 and verb == "PUT":
        putTournamentRoute(request, ctx.get, user.get, parts[4])
        return
      if parts.len == 5 and verb == "DELETE":
        deleteTournamentRoute(request, ctx.get, user.get, parts[4])
        return
      if parts.len == 7 and parts[5] == "matches" and verb == "PATCH":
        patchTournamentMatchRoute(request, ctx.get, user.get, parts[4], parts[6])
        return
      if parts.len == 6 and parts[5] == "rating" and verb in ["POST", "DELETE"]:
        # matrix.yaml: both rating operations are admin-only.
        let admin = adminGate(request, parts[2])
        if admin.isNone: return
        if verb == "POST":
          ingestTournamentRating(request, admin.get[1], admin.get[0], parts[4])
        else:
          clearTournamentRating(request, admin.get[1], admin.get[0], parts[4])
        return
      problem(request, 404, "NOT_FOUND", "route not found")
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
      if parts[3] == "rating-sources" and parts.len == 5 and verb == "PATCH":
        patchRatingSource(request, admin.get[1], admin.get[0], parts[4])
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
      # The effective config is what a member's screen reads (export sizes,
      # page limits). Community settings are readable by members too, so this
      # cannot be admin-only without breaking every page a host opens.
      if parts[3] == "config" and parts.len == 4 and verb == "GET":
        let user = requireUser(request)
        if user.isNone: return
        let (decision, ctx) = decide(user.get,
          cookieValue(request, "majadu_session"), parts[2], readAccess())
        if decision != gAllowed:
          respondGate(request, decision)
          return
        communityConfig(request, ctx.get)
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
      problem(request, 404, "NOT_FOUND", "route not found")
      return
    # /c/{slug}/settings
    if parts.len == 4 and parts[1] == "c" and parts[3] == "settings":
      if verb == "GET":
        let user = currentUser(request)
        if user.isNone:
          problem(request, 401, "UNAUTHENTICATED", "login required")
          return
        let (decision, ctx) = decide(user.get,
          cookieValue(request, "majadu_session"), parts[2], readAccess())
        if decision != gAllowed:
          respondGate(request, decision)
          return
        getCommunitySettings(request, ctx.get)
      elif verb == "PATCH":
        # Settings are admin-only: a host raises scores, not the ceiling.
        let admin = adminGate(request, parts[2])
        if admin.isNone: return
        patchCommunitySettings(request, admin.get[1], admin.get[0])
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
        rankingPlayer(request, ctx.get.communityId, ctx.get.timezone,
          parts[4])
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
      if parts.len == 5 and parts[3] == "rankings":
        getSharedRanking(request, code, parts[4])
        return
      if parts.len == 4 and parts[3] == "ws-ticket" and verb == "POST":
        issueShareTicket(request, code)
        return
    problem(request, 404, "NOT_FOUND", "route not found")
  except DbError as error:
    if error.sqlState in ["23001", "23503"]:
      # PostgreSQL reports ON DELETE RESTRICT as 23001, not 23503: the player
      # delete used to fall through to the 500 branch because of that.
      problem(request, 409, "CONFLICT", "the row is still referenced by other data")
      return
    if error.sqlState in ["23502", "23514", "54000"]:
      # A not-null/check violation or an identifier too large for its index is
      # a body problem, not an internal fault.
      problem(request, 400, "INVALID_INPUT", "a value does not satisfy the schema")
      return
    if error.sqlState in ["22P02", "22007", "22008"]:
      # A path segment or body value that cannot become the uuid, date or time
      # the statement casts it to is the caller's mistake, not an internal
      # fault. PostgreSQL raises it before a row is read, so one guard here
      # turns every `$n::uuid` / `::date` / `::time` cast into a 400.
      problem(request, 400, "INVALID_INPUT", "a value has the wrong format")
      return
    # Driver messages echo input values; the logger redacts and emits one JSON
    # line, so a crafted path cannot forge log rows or leak a share code.
    logError("request failed", [("error", error.msg), ("path", request.path)])
    problem(request, 500, "INTERNAL", "internal error")
  except CatchableError as error:
    # Driver messages echo input values; the logger redacts and emits one JSON
    # line, so a crafted path cannot forge log rows or leak a share code.
    logError("request failed", [("error", error.msg), ("path", request.path)])
    problem(request, 500, "INTERNAL", "internal error")

proc secureCookies(oidc: OidcConfig): bool =
  ## An explicit flag wins, but it cannot contradict the deployment: a public
  ## https redirect URI served with a plain cookie leaks the session, so that
  ## combination refuses to start. Without the flag the redirect URI decides,
  ## which makes a new production deployment secure by default.
  case getEnv("MAJADU_COOKIE_SECURE").strip()
  of "1":
    true
  of "0":
    if oidc.redirectUri.startsWith("https://"):
      raise newException(ValueError,
        "MAJADU_COOKIE_SECURE=0 cannot serve an https redirect URI")
    false
  else:
    oidc.redirectUri.startsWith("https://")

proc newApp*(db: Db, oidc: OidcConfig, keyring: Keyring,
             config: ConfigCache): App =
  App(db: db, oidc: oidc, keyring: keyring, config: config,
      limiter: newLimiter(),
      hub: newHub(db),
      cookieSecure: secureCookies(oidc),
      bootstrapOwner: getEnv("MAJADU_BOOTSTRAP_OWNER_EMAIL").strip().toLowerAscii())

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
