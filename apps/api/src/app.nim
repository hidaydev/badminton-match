import std/[base64, json, locks, options, os, sets, strutils, sysrand, tables, times, uri]
import mummy
import auth_middleware
import clock
import community_context
import community_time
import community/domain/community as communityDomain
import community/infrastructure/community_store
import community/infrastructure/invite as inviteStore
import community/infrastructure/join_request as joinRequestStore
import community/infrastructure/membership as membershipStore
import community/infrastructure/membership_sql as membershipSql
import config as edgeConfig
import config_routes
import errors as platformErrors
import live
import logger
import quota_route
import ratelimit
import route_access
import security_headers
import server
import db/db
import sha256
import share/crypto
import share/store as shareStore
import session/write as sessionWrite
import session/application/detail as sessionDetail
import session/standings as sessionStandings
import session/schedule as sessionSchedule
import session/scoring as sessionScoring
import session/sides as sessionSides
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
import rating/infrastructure/jobs as ratingJobs
import rating/infrastructure/tournament as ratingTournament
import rating/infrastructure/params as ratingParams
import rating/read as ratingRead
import achievement/infrastructure/backfill as achievementBackfill
import account/domain/lifecycle as accountLifecycle
import account/domain/audit
import account/domain/roles
import account/infrastructure/audit_store
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
  IdentityEntry = object
    userId: string
    expires: float

  IdentityCache = ref object
    ## Token hash to user id for a few seconds. A browser sends one cookie and
    ## reuses it on every request, so without this the limiter's own identity
    ## check is a `SELECT` per request. The bound keeps random cookies from
    ## growing the table, and `lookups` is the count the suites read to prove
    ## that a rejected cookie does not reach the database.
    lock: Lock
    entries: Table[string, IdentityEntry]
    lookups: int

  App* = ref object
    db*: Db
    oidc*: OidcConfig
    keyring*: Keyring
    config*: ConfigCache
    limiter*: Limiter
    identityCache: IdentityCache
    ratingJobs*: ratingJobs.RatingJobs
    hub*: LiveHub
    cookieSecure*: bool
    bootstrapOwner*: string

  AuthUser = object
    id*: string
    emailHash*: string
    displayName*: string
    isOwner*: bool
    token*: string

var application: App

# `route()` computes the quota label once and `send` hands it to the counter
# instead of deriving it again. Each connection is served on a single worker
# thread, so a threadvar cannot leak a label between requests.
var currentRouteLabel {.threadvar.}: string

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

proc evidenceEvent(action: string, communityId: string, user: AuthUser,
                   targetKind: string, targetId: string, after: JsonNode,
                   role: string): AuditEvent =
  ## The row every privileged write leaves. Field names outside the domain
  ## allowlist are dropped inside the adapter, never written. The role is what
  ## the membership actually granted, so a host write does not read as admin.
  auditEvent(action, communityId,
    actorId = user.id,
    actorRole = (if user.isOwner: "platform_owner"
                 elif role.len > 0: role
                 else: "admin"),
    targetKind = targetKind, targetId = targetId,
    requestId = currentRequestId()).withEvidence(
      newJObject(), after)

proc auditConn(conn: DbConn, action: string, communityId: string, user: AuthUser,
               targetKind: string, targetId: string,
               after: JsonNode = newJObject(), role = "") =
  ## Same evidence, written on the connection of the transaction that performs
  ## the privileged write, so the row and the write commit together.
  recordAuditConn(conn, evidenceEvent(action, communityId, user, targetKind,
    targetId, after, role))

proc auditConn(conn: DbConn, action: string, ctx: CommunityContext, user: AuthUser,
               targetKind: string, targetId: string,
               after: JsonNode = newJObject()) =
  ## Community route overload: the membership role is already resolved.
  auditConn(conn, action, ctx.communityId, user, targetKind, targetId, after,
    $ctx.role)

proc authAudit(action: string, user: AuthUser, outcome = arAllow,
               reason = "") =
  ## Auth events belong to no community, so the row carries none. The role is
  ## the platform one, because a lesson learned here is about a person's
  ## sessions, not about a membership.
  recordAudit(application.db, auditEvent(action, communityId = "",
    actorId = user.id,
    actorRole = (if user.isOwner: "platform_owner" else: "member"),
    outcome = outcome, targetKind = "user", targetId = user.id,
    reason = reason, requestId = currentRequestId()))

proc authRejected(action, reason: string, userId = "") =
  ## A rejected attempt before any session exists: who is unknown unless the
  ## account was already resolved. Only the reason is kept, never the token.
  recordAudit(application.db, auditEvent(action, communityId = "",
    actorId = userId, actorRole = "anonymous", outcome = arDeny,
    targetKind = (if userId.len > 0: "user" else: ""), targetId = userId,
    reason = reason, requestId = currentRequestId()))

type WriteRefusal* = object of CatchableError
  ## Raised inside `auditedWrite` when the write must not land but the route
  ## still has a normal 4xx answer. The transaction rolls back and the caller
  ## turns the refusal into the response.

proc auditedWrite(body: proc(tx: Db, conn: DbConn)) =
  ## One transaction for a privileged write and its evidence. The store helper
  ## receives a facade bound to this connection, so a helper that takes a `Db`
  ## cannot check out a second connection and commit before the audit row. If
  ## either the write or the audit fails, both roll back.
  application.db.tx(proc(conn: DbConn) =
    body(application.db.boundTo(conn), conn))

proc send(request: Request, status: int,
          headers: openArray[(string, string)], body: string) =
  ## Single response path: every response carries the security headers, so a new
  ## route cannot silently ship without CSP or nosniff. A response with a body
  ## is never cacheable either, and 204 is the one bodiless status that still
  ## needs the directive; a caller that set `Cache-Control` itself keeps it.
  var merged = @headers
  var declaresCache = false
  for pair in merged:
    if cmpIgnoreCase(pair[0], "Cache-Control") == 0:
      declaresCache = true
  if not declaresCache and (status == 204 or body.len > 0):
    merged.add(("Cache-Control", "no-store"))
  for pair in securityHeaders(application.cookieSecure):
    merged.add(pair)
  request.respond(status, merged, body)
  # The pool is sampled on every answer so `/metrics` reports the state of the
  # last request; a scrape-only read would need the listener to hold the pool.
  let pool = application.db.poolStats()
  recordPool(pool.size, pool.available, pool.inUse)
  discard recordResponse(request.httpMethod, request.path, status,
    currentRouteLabel, currentRequestId())

proc send(request: Request, status: int) =
  send(request, status, newSeq[(string, string)](), "")

proc send(request: Request, status: int, body: string) =
  send(request, status, @[("Content-Type", "application/json")], body)

proc jsonResponse(request: Request, status: int, body: JsonNode,
                  extra: openArray[(string, string)] = [],
                  cacheable = false) =
  ## A JSON body belongs to a session or a community, so `no-store` is the
  ## default; a caller that really wants a shared cache opts in.
  var headers = @[("Content-Type", "application/json")]
  if not cacheable:
    headers.add(("Cache-Control", "no-store"))
  for pair in extra:
    headers.add(pair)
  send(request, status, headers, $body)

proc sendProblem(request: Request, status: int, contentType: string,
                 body: platformErrors.Problem, extra: JsonNode = nil,
                 headers: openArray[(string, string)] = []) =
  ## `extra` adds members the envelope does not carry on every route (`issues`,
  ## `retryAfter`); it is merged over the canonical fields rather than replacing
  ## them, so the shape stays one shape.
  var node = parseJson(body.toJson())
  if extra != nil:
    for key, value in extra:
      node[key] = value
  var merged = @[("Content-Type", contentType)]
  for pair in headers:
    merged.add(pair)
  send(request, status, merged, $node)

proc problem(request: Request, status: int, code, detail: string,
             extra: JsonNode = nil,
             headers: openArray[(string, string)] = []) =
  ## One envelope for every rejection. The body is built by platform-lib so the
  ## shape, the i18nKey lookup and the detail redaction cannot drift per route.
  sendProblem(request, status, "application/problem+json",
    platformErrors.newProblem(status, code, platformErrors.i18nKeyFor(code),
      detail), extra, headers)

proc redactIssues(issues: JsonNode): JsonNode =
  ## The wizard renders each `detail` verbatim and the domain echoes the
  ## submitted values there, so every message goes through the same redactor as
  ## the envelope's own detail.
  result = newJArray()
  for issue in issues:
    if issue.kind != JObject:
      result.add(issue)
      continue
    var copy = newJObject()
    for key, value in issue:
      copy[key] = value
    if copy.hasKey("detail") and copy["detail"].kind == JString:
      copy["detail"] = %redact(copy["detail"].getStr())
    result.add(copy)

proc invalidBodyResponse(request: Request, code, detail: string,
                         snapshot: JsonNode) =
  ## A rejected tournament body keeps the field-level `issues` the wizard
  ## renders, but it is still a 4xx and must carry the one error envelope:
  ## status, code and i18nKey. The issues are an extension of that envelope,
  ## not a second body, so a client never has to read two shapes.
  var extra: JsonNode = nil
  if snapshot.hasKey("issues"):
    extra = newJObject()
    extra["issues"] = redactIssues(snapshot["issues"])
  problem(request, 400, code, detail, extra)

proc methodNotAllowed(request: Request) =
  ## A known path with an unsupported verb answers 405, so a caller can tell a
  ## typo apart from the 404 that hides a community it may not see.
  problem(request, 405, "METHOD", "")

proc routeNotFound(request: Request) =
  problem(request, 404, "NOT_FOUND", "route not found")

proc originNotAllowed(request: Request) =
  ## The one refusal for an origin outside the allowlist. The request chain and
  ## the WebSocket handshake reach it from different guards but answer alike.
  problem(request, 403, "CSRF_REJECTED", "origin is not allowed")

proc cookieValue(request: Request, name: string): string =
  let header = request.headers["Cookie"]
  for part in header.split(';'):
    let pair = part.strip().split('=', maxsplit = 1)
    if pair.len == 2 and pair[0] == name:
      return pair[1]
  ""

proc configSnapshot(): Snapshot =
  ## Every call probes `platform.config_version` before it can reuse the cache,
  ## so `route` takes one snapshot per request and hands it to the handler. This
  ## stays for helpers that read a single key and are called outside that chain.
  application.config.snapshot(application.db)

proc database(): Db =
  ## The process pool, named once. A handler receives it from here instead of
  ## reaching for the global in every routine; the archcheck allowlist records
  ## this single routine as the documented exception (BE-06).
  application.db

proc scoringPresets(snapshot: Snapshot): seq[sessionScoring.ScoringRules] =
  ## The platform list. It is reference data for the wizard, not a community
  ## setting, so every community sees the same formats.
  sessionScoring.parsePresets(
    snapshot.jsonValue(%*{}, keySessionScoringPresets))

proc findPreset(snapshot: Snapshot,
                id: string): Option[sessionScoring.ScoringRules] =
  for preset in scoringPresets(snapshot):
    if preset.id == id:
      return some(preset)
  none(sessionScoring.ScoringRules)

proc bodyJson(request: Request, snapshot: Snapshot): JsonNode =
  if request.body.len == 0:
    return %*{}
  # Refused before parsing: `parseJson` walks the nesting, so the depth can only
  # be checked on the raw text. `/auth/start` is unauthenticated and parses
  # before anything else, which is why this door enforces the limit.
  if jsonTooDeep(request.body,
      snapshot.intValue(%*{}, keySecurityMaxJsonDepth)):
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

proc jsonBody(request: Request, snapshot: Snapshot,
              body: var JsonNode): bool =
  ## `false` means the 400 was already sent, so every handler branches the same
  ## way instead of repeating the try/except.
  try:
    body = bodyJson(request, snapshot)
    true
  except ValueError:
    problem(request, 400, "INVALID_BODY", "body must be JSON")
    false

proc optStr(body: JsonNode, key: string, fallback = ""): string =
  ## `getStr` answers "" on a kind mismatch, which silently drops a numeric
  ## value; a non-string is treated as absent instead.
  if body.kind == JObject and body.hasKey(key) and body[key].kind == JString:
    body[key].getStr()
  else:
    fallback

type
  RateIdentity = object
    ## The limiter key plus the address that minted it. The address travels
    ## with the key so the limiter can bound how many buckets one client owns.
    key: string
    address: string

const
  ## A validated cookie is reused for this many seconds before it is looked up
  ## again. Revocation already happens in `resolve` on the route that needs the
  ## user; this cache only decides the limiter key.
  identityCacheSeconds = 15.0
  ## Hard bound on the table. Reaching it evicts the entry closest to expiry,
  ## so random cookies cannot grow it without limit.
  identityCacheMaxEntries = 2048

proc newIdentityCache(): IdentityCache =
  result = IdentityCache(entries: initTable[string, IdentityEntry]())
  initLock(result.lock)

proc identityLookups(cache: IdentityCache): int =
  ## How many token-to-user lookups reached the database. A test reads this to
  ## prove that a rejected cookie does not query `account.sessions`.
  acquire(cache.lock)
  try:
    result = cache.lookups
  finally:
    release(cache.lock)

proc knows(cache: IdentityCache, token: string, now: float): bool =
  ## True when the token was validated recently. The pre-limit consults this
  ## first, so a browser that keeps the same cookie costs one lookup per
  ## window instead of one per request.
  let key = sha256Hex(token)
  acquire(cache.lock)
  try:
    let entry = cache.entries.getOrDefault(key)
    result = entry.userId.len > 0 and entry.expires > now
  finally:
    release(cache.lock)

proc cachedUserId(cache: IdentityCache, db: Db, token: string, idleDays: int,
                  now: float): Option[string] =
  ## Validates a token once per window and bounds the table. Called without
  ## the cache lock so a slow PostgreSQL round trip never serialises other
  ## requests' cache hits.
  let key = sha256Hex(token)
  acquire(cache.lock)
  try:
    let entry = cache.entries.getOrDefault(key)
    if entry.userId.len > 0 and entry.expires > now:
      return some(entry.userId)
    if entry.userId.len > 0:
      cache.entries.del(key)
    inc cache.lookups
  finally:
    release(cache.lock)
  let found = validUserId(db, token, idleDays)
  if found.isSome:
    acquire(cache.lock)
    try:
      if cache.entries.len >= identityCacheMaxEntries:
        var oldestKey = ""
        var oldest = 0.0
        for candidate, entry in cache.entries:
          if oldestKey.len == 0 or entry.expires < oldest:
            oldestKey = candidate
            oldest = entry.expires
        if oldestKey.len > 0:
          cache.entries.del(oldestKey)
      cache.entries[key] = IdentityEntry(userId: found.get,
        expires: now + identityCacheSeconds)
    finally:
      release(cache.lock)
  found

const identityPreLimitFactor* = 4

proc rateLimited(request: Request, decision: Decision) =
  ## A 429 is not a second shape: it is the same envelope with `retryAfter`
  ## added, and the header repeats it for clients that do not read the body.
  problem(request, 429, "RATE_LIMITED", "too many requests",
    %*{"retryAfter": decision.retryAfter},
    [("Retry-After", $decision.retryAfter), ("Cache-Control", "no-store")])

proc preLimit(request: Request, snapshot: Snapshot, address: string,
              now: float): bool =
  ## Address budget charged only before a database validation. A genuine
  ## browser is validated once per cache window, so a busy NAT of signed-in
  ## users is far below it; an unknown cookie is validated on every request it
  ## arrives on, so this is what stops random cookies before a query. `true`
  ## means the 429 was already sent.
  let limit = snapshot.intValue(%*{}, keySecurityRateLimitPerMinute) *
    identityPreLimitFactor
  let budget = application.limiter.hit("identity|" & address, limit, now,
    address)
  if budget.allowed:
    return false
  rateLimited(request, budget)
  true

proc requestIdentity(request: Request, snapshot: Snapshot,
                     address: string): RateIdentity =
  ## Production sits behind a CDN edge, so the TCP-derived address is the same
  ## for everyone and a per-address quota would be a platform-wide quota. A
  ## genuine session is keyed by its user id; an anonymous caller, and any
  ## client that presents an unknown, expired or malformed cookie, keeps the
  ## address. The cookie only becomes a key after `account.sessions` confirms
  ## it, so rotating a random cookie cannot mint buckets.
  let token = cookieValue(request, "majadu_session")
  if token.len > 0:
    let idleDays = snapshot.intValue(%*{}, keySessionIdleDays)
    try:
      let userId = application.identityCache.cachedUserId(application.db,
        token, idleDays, utcNow().toTime.toUnixFloat)
      if userId.isSome:
        recordIdentitySource("cookie")
        return RateIdentity(key: "user:" & userId.get, address: address)
    except DbError:
      # A session lookup that cannot reach the database must not turn a read
      # into a 500: the address path is a safe, coarser fallback.
      discard
  # An anonymous caller, or a cookie the database did not confirm, is named by
  # the edge when a trusted proxy asserted an address and by the TCP peer
  # otherwise. The metric makes a misconfigured trusted-proxy list visible:
  # everything collapses to `peer` and the per-viewer budget becomes one global
  # budget.
  let source =
    if edgeConfig.forwardedIp(request, edgeConfig.trustedProxies()).len > 0:
      "header"
    else:
      "peer"
  recordIdentitySource(source)
  RateIdentity(key: address, address: address)

proc quota(request: Request, snapshot: Snapshot, scope, key, address: string,
           limit: int, evictable = false): bool =
  ## One limiter call and one 429 for every budget. `scope` names the bucket and
  ## `key` is what is counted inside it, so the route budget, a share link and an
  ## invite request share the window and the body instead of each keeping their
  ## own copy. `true` means the 429 was already sent.
  let budget = application.limiter.hit(scope & "|" & key, limit,
    utcNow().toTime.toUnixFloat, address, evictable)
  if budget.allowed:
    return false
  rateLimited(request, budget)
  true

proc quota(request: Request, snapshot: Snapshot, scope: string,
           identity: RateIdentity, limit: int, evictable = false): bool =
  quota(request, snapshot, scope, identity.key, identity.address, limit,
    evictable)

proc sessionCookie(token: string, snapshot: Snapshot): string =
  let days = snapshot.intValue(%*{}, keySessionAbsoluteDays)
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

proc createSessionToken(userId: string, snapshot: Snapshot): string =
  let days = snapshot.intValue(%*{}, keySessionAbsoluteDays)
  createSession(application.db, userId, days)

proc currentUser(request: Request, snapshot: Snapshot): Option[AuthUser] =
  let token = cookieValue(request, "majadu_session")
  if token.len == 0:
    return none(AuthUser)
  let idleDays = snapshot.intValue(%*{}, keySessionIdleDays)
  let user = resolve(application.db, token, idleDays)
  if user.isNone:
    return none(AuthUser)
  some(AuthUser(
    id: user.get.userId,
    emailHash: user.get.emailHash,
    displayName: user.get.displayName,
    isOwner: user.get.isPlatformOwner,
    token: token,
  ))

proc requireUser(request: Request, snapshot: Snapshot): Option[AuthUser] =
  result = currentUser(request, snapshot)
  if result.isNone:
    problem(request, 401, "UNAUTHENTICATED", "login required")

proc actorOf(user: AuthUser): Actor =
  Actor(userId: user.id, isPlatformOwner: user.isOwner,
    sessionToken: user.token)

proc decide(user: AuthUser, slug: string,
            access: Access): (Gate, Option[CommunityContext]) =
  ## Membership is resolved before the gate so a foreign slug is a 404, not a
  ## 403 that confirms the community exists.
  let ctx = loadCommunity(application.db, user.id, slug)
  (gate(access, some(actorOf(user)), ctx), ctx)

proc respondGate(request: Request, decision: Gate) =
  problem(request, statusFor(decision), codeFor(decision), codeFor(decision))

proc denyAudit(user: AuthUser, community: Option[CommunityContext],
               slug: string) =
  ## A refused request from an authenticated principal leaves one row. Without
  ## it a member walking another community's surface, or a script probing a
  ## route it may not use, leaves only a counter nobody scrapes.
  ##
  ## Anonymous refusals are not recorded here: they have no actor and their
  ## volume is one row per scanner request. The route is the matched contract
  ## shape, never the raw path, so the evidence cannot carry a slug-shaped
  ## invention. A failed insert must not turn the refusal into a 500.
  let communityId = if community.isSome: community.get.communityId else: ""
  let role =
    if user.isOwner: "platform_owner"
    elif community.isSome: $community.get.role
    else: "member"
  try:
    recordAudit(application.db, auditEvent("authz.denied", communityId,
      actorId = user.id, actorRole = role, outcome = arDeny,
      targetKind = "route", targetId = currentRouteLabel,
      reason = "denied " & currentRouteLabel,
      requestId = currentRequestId()).withEvidence(newJObject(),
        %*{"route": currentRouteLabel, "slug": slug}))
  except DbError as error:
    logError("denied request not audited",
      [("error", error.msg), ("route", currentRouteLabel)])

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

proc startAuth(request: Request, snapshot: Snapshot) =
  var body: JsonNode
  if not jsonBody(request, snapshot, body):
    return
  let returnTo = optStr(body, "returnTo", "/")
  let safeReturn = safeReturnPath(returnTo)
  let state = randomHex(32)
  let nonce = randomHex(32)
  let verifier = randomHex(32)
  let challenge = b64url(sha256Raw(verifier))
  let (keyId, encrypted) = encryptWith(application.keyring, verifier, state)
  let ttl = snapshot.intValue(%*{}, keyAuthFlowTtlMinutes)
  discard application.db.execUpdate(
    """insert into auth.oauth_flows
       (state_hash, nonce_hash, code_verifier_enc, key_id, return_to, expires_at)
       values (decode($1,'hex'), decode($2,'hex'), decode($3,'hex'), $4, $5,
               now() + make_interval(mins => $6))""",
    @[textParam(sha256Hex(state)), textParam(sha256Hex(nonce)),
      textParam(bytesHex(encrypted)), textParam(keyId),
      textParam(safeReturn), intParam(ttl.int64)])
  jsonResponse(request, 200, %*{
    "authorizeUrl": authorizeUrl(application.oidc, state, nonce, challenge),
  }, [("Set-Cookie", authFlowCookie(state))])

proc finishAuth(request: Request, snapshot: Snapshot) =
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
         returning nonce_hash, code_verifier_enc, key_id, return_to)
       select encode(nonce_hash,'hex') as nonce_hash,
              encode(code_verifier_enc,'hex') as verifier_enc,
              key_id, return_to
       from deleted""",
    @[textParam(sha256Hex(state))])
  if row.isNone:
    problem(request, 400, "INVALID_STATE", "flow not found, expired or already used")
    return
  let flow = row.get
  var verifier = ""
  try:
    # The key that encrypted the verifier, not the key that happens to be
    # active now: a rotation between start and finish must not break the login.
    verifier = decryptWith(application.keyring, flow.get("key_id"),
      hexBytes(flow.get("verifier_enc")), state)
  except ShareKeyError:
    problem(request, 500, "KEY_ERROR", "cannot decrypt flow")
    return
  var idToken = ""
  try:
    idToken = exchangeCode(application.oidc, code, verifier)
  except CatchableError as error:
    logError("token exchange failed",
      [("error", error.msg), ("path", request.path)])
    problem(request, 400, "TOKEN_EXCHANGE_FAILED", "token exchange failed")
    return
  var claims: JsonNode
  try:
    claims = verifyIdTokenWithRefresh(application.oidc, idToken,
      application.oidc.issuer, application.oidc.clientId, "",
      utcNow().toTime.toUnix)
  except CatchableError as error:
    authRejected("auth.login.rejected", "invalid id token")
    logError("id token rejected",
      [("error", error.msg), ("path", request.path)])
    problem(request, 401, "INVALID_ID_TOKEN", "id token is invalid")
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
  # with the community) are honoured at login. Only a membership this login
  # created is audited: a returning member already holds the grant, and a second
  # `community.join` row would claim they joined twice.
  let loginUser = AuthUser(id: userRow.get.get("id"),
    isOwner: userRow.get.get("is_platform_owner") == "t")
  application.db.tx(proc(conn: DbConn) =
    for grant in inviteStore.acceptPendingForEmail(application.db.boundTo(conn),
        loginUser.id, sha256Hex(email)):
      auditConn(conn, "community.join", grant.communityId, loginUser, "community",
        grant.communityId, %*{"role": grant.role}, grant.role))
  let token = createSessionToken(userRow.get.get("id"), snapshot)
  authAudit("auth.login", AuthUser(id: userRow.get.get("id"),
    isOwner: userRow.get.get("is_platform_owner") == "t"))
  send(request, 302,
    @[("Location", safeReturnPath(flow.get("return_to"))),
      ("Set-Cookie", sessionCookie(token, snapshot)),
      ("Set-Cookie",
        "majadu_auth_flow=; Path=/; HttpOnly; SameSite=Lax; Max-Age=0")], "")

proc listAuthSessions(request: Request, snapshot: Snapshot) =
  let user = requireUser(request, snapshot)
  if user.isNone: return
  var items = newJArray()
  for row in listSessions(application.db, user.get.id, user.get.token):
    items.add(%*{"id": row.id, "createdAt": row.createdAt,
      "lastSeenAt": row.lastSeenAt, "current": row.current})
  jsonResponse(request, 200, %*{"items": items})

proc revokeOtherSessions(request: Request, snapshot: Snapshot) =
  let user = requireUser(request, snapshot)
  if user.isNone: return
  revokeOthers(application.db, user.get.id, user.get.token)
  application.hub.revokePrincipal(user.get.id)
  authAudit("auth.sessions.revoke_others", user.get)
  send(request, 204)

proc me(request: Request, snapshot: Snapshot) =
  let user = requireUser(request, snapshot)
  if user.isNone: return
  ## The body names the caller, so a shared cache must never hold it.
  jsonResponse(request, 200, %*{
    "id": user.get.id,
    "displayName": user.get.displayName,
    "platformOwner": user.get.isOwner,
  })

proc logout(request: Request, snapshot: Snapshot) =
  let token = cookieValue(request, "majadu_session")
  let user = currentUser(request, snapshot)
  if token.len > 0:
    revoke(application.db, token)
  # Sockets and every ticket of the principal close with the session.
  if user.isSome:
    application.hub.revokePrincipal(user.get.id)
    authAudit("auth.logout", user.get)
  send(request, 204, @[("Set-Cookie",
    "majadu_session=; Path=/; HttpOnly; SameSite=Lax; Max-Age=0")], "")

proc ownerOnly(request: Request, snapshot: Snapshot): Option[AuthUser] =
  ## Platform-owner management routes: 401 before 403, never a community check.
  result = requireUser(request, snapshot)
  if result.isNone:
    return
  if not result.get.isOwner:
    problem(request, 403, "FORBIDDEN", "platform owner only")
    return none(AuthUser)

proc scoped(request: Request, snapshot: Snapshot, slug: string,
            access: Access): Option[(AuthUser, CommunityContext)] =
  ## The shared preamble of every `/c/{slug}/...` prefix: resolve the caller,
  ## load the membership and answer the gate. A foreign slug stays a 404, so
  ## the role check never confirms that a community exists.
  let user = requireUser(request, snapshot)
  if user.isNone:
    return none((AuthUser, CommunityContext))
  let (decision, ctx) = decide(user.get, slug, access)
  if decision != gAllowed:
    if decision == gForbidden:
      denyAudit(user.get, ctx, slug)
    respondGate(request, decision)
    return none((AuthUser, CommunityContext))
  some((user.get, ctx.get))

proc createCommunity(request: Request, snapshot: Snapshot) =
  let user = ownerOnly(request, snapshot)
  if user.isNone:
    return
  var body: JsonNode
  if not jsonBody(request, snapshot, body):
    return
  let slug = optStr(body, "slug")
  let name = optStr(body, "name")
  let adminEmail = optStr(body, "adminEmail")
  let rawTimezone = optStr(body, "timezone")
  let timezone = if rawTimezone.len > 0: some(rawTimezone) else: none(string)
  let check = communityDomain.checkCreate(slug, name, adminEmail,
    snapshot.stringValue(%*{}, keyCommunityDefaultTimezone), timezone)
  if check.problems.len > 0:
    problem(request, 400, "INVALID_COMMUNITY", $check.problems[0])
    return
  # The zone decides which calendar day a session belongs to, so an unknown name
  # is a bad request, not a value to store and fail on later.
  if not validTimezone(application.db, check.timezone):
    problem(request, 400, "INVALID_COMMUNITY",
      "timezone is not a known IANA zone")
    return
  var created: communityStore.CreateResult
  auditedWrite(proc(tx: Db, conn: DbConn) =
    created = communityStore.create(tx, check.slug, name.strip(),
      adminEmail, check.timezone, user.get.id)
    if created.status == csOk:
      auditConn(conn, "community.create", created.communityId, user.get,
        "community", created.communityId, %*{"slug": check.slug}))
  case created.status
  of csSlugTaken:
    problem(request, 409, "SLUG_TAKEN", "community slug already exists")
  of csOk:
    jsonResponse(request, 201, %*{
      "id": created.communityId,
      "slug": check.slug,
      "name": name.strip(),
      "timezone": check.timezone,
    })

proc listCommunities(request: Request,
                    snapshot: Snapshot) =
  let user = requireUser(request, snapshot)
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

proc normalizeClockTime(value: string): Option[string] =
  ## Two-digit fields, so "9:00" is refused rather than guessed. Some write
  ## responses format a `time::text` as HH:MM:SS, so that shape round-trips;
  ## non-zero seconds are refused because the column only stores minutes.
  for pattern in ["HH:mm", "HH:mm:ss"]:
    try:
      let parsed = parse(value, pattern, utc())
      if parsed.format(pattern) == value and parsed.second == 0:
        return some(parsed.format("HH:mm"))
    except TimeParseError:
      discard
  none(string)

proc idempotencyKey(communityId, key, resource: string): string =
  ## The key is scoped to the resource the write touches. Without the resource,
  ## the same key and body sent to two different sessions or tournaments
  ## replayed the first response and left the second unchanged.
  scopedKey(communityId & (if resource.len > 0: "/" & resource else: ""), key)

type
  WriteKey = object
    ## One write's claim on `platform.idempotency_keys`. Claim, release, and
    ## complete read the same four fields, so they cannot disagree about which
    ## row they own; a hand-typed scope per branch used to let them.
    userId: string
    communityId: string
    key: string
    resource: string

proc storageKey(w: WriteKey): string =
  ## The single place that turns a claim into the row's key.
  idempotencyKey(w.communityId, w.key, w.resource)

proc release(w: WriteKey) =
  ## A failed attempt must not own the key: the retry with a corrected body
  ## would otherwise answer 409 for the rest of the TTL.
  if w.key.len == 0:
    return
  discard application.db.execUpdate(
    """delete from platform.idempotency_keys
       where user_id = $1::uuid and key = $2""",
    @[textParam(w.userId), textParam(storageKey(w))])

proc complete(w: WriteKey, status: int, body: JsonNode) =
  ## Stores the response under the row the claim took, so a replay returns it.
  if w.key.len == 0:
    return
  complete(application.db, w.userId, storageKey(w), status, body)

proc claimWrite(request: Request, ctx: CommunityContext, user: AuthUser,
                resource = ""): Option[WriteKey] =
  ## None means the answer was already sent: a replay of the same body gets the
  ## stored response, and the same key with a different body gets a 409. Some
  ## means the caller owns the key and must do the work.
  let w = WriteKey(userId: user.id, communityId: ctx.communityId,
    key: request.headers["Idempotency-Key"], resource: resource)
  if w.key.len == 0:
    return some(w)
  let entry = claim(application.db, w.userId, storageKey(w),
    bodyHash(request.body))
  case entry.status
  of idempotencyNew:
    some(w)
  of idempotencyReplay:
    jsonResponse(request, entry.statusCode, entry.response)
    none(WriteKey)
  of idempotencyInProgress:
    problem(request, 409, "IDEMPOTENCY_IN_PROGRESS",
      "this key is still being processed; retry shortly",
      %*{"retryAfter": 2}, [("Retry-After", "2")])
    none(WriteKey)
  of idempotencyConflict:
    problem(request, 409, "IDEMPOTENCY_CONFLICT",
      "this key was used with a different body")
    none(WriteKey)

proc createSession(request: Request, ctx: CommunityContext, user: AuthUser,
                   snapshot: Snapshot) =
  var body: JsonNode
  if not jsonBody(request, snapshot, body):
    return
  var title = ""
  var date = ""
  var startTime = "00:00"
  var presetId = ""
  var slot = snapshot.intValue(%*{}, keySessionSlotMinutesDefault)
  try:
    # `getStr`/`getInt` answer their default on a kind mismatch, so each field
    # is type-checked before it is read: a numeric title must not become "".
    if body.hasKey("title"): title = jsonString(body, "title")
    if body.hasKey("date"): date = jsonString(body, "date")
    if body.hasKey("startTime"): startTime = jsonString(body, "startTime")
    if body.hasKey("scoringPreset"): presetId = jsonString(body, "scoringPreset")
    if body.hasKey("slotMinutes"):
      if body["slotMinutes"].kind != JInt:
        raise newException(ValueError, "slotMinutes must be an integer")
      slot = body["slotMinutes"].getInt()
  except ValueError:
    problem(request, 400, "INVALID_BODY",
      "title, date, startTime, scoringPreset and slotMinutes must have the documented types")
    return
  # Without these checks the insert reached PostgreSQL and a bad date, time or
  # slot became a 500. The contract already documents a 400 for this route.
  if not validSessionDate(date):
    problem(request, 400, "INVALID_BODY", "date must be a real YYYY-MM-DD day")
    return
  let clock = normalizeClockTime(startTime)
  if clock.isNone:
    problem(request, 400, "INVALID_BODY", "startTime must be HH:MM or HH:MM:SS")
    return
  startTime = clock.get
  if slot < 1 or slot > 240:
    problem(request, 400, "INVALID_BODY", "slotMinutes must be between 1 and 240")
    return
  try:
    # A blank title used to be stored as-is, so the list showed nameless
    # drafts; the create form always sends one.
    title = sessionWrite.parseTitle(title)
  except ValueError as error:
    logWarn("session title rejected",
      [("error", error.msg), ("path", request.path)])
    problem(request, 400, "INVALID_BODY", error.msg)
    return
  if presetId.len == 0:
    presetId = snapshot.stringValue(ctx.settings, keySessionDefaultScoringPreset)
  let chosen = findPreset(snapshot, presetId)
  if chosen.isNone:
    problem(request, 400, "INVALID_PRESET", "unknown scoring preset")
    return
  # Claim the key only once the body is known to be valid: a 400 must not leave
  # the key owned, or every retry would answer 409 for the rest of the day.
  let claimed = claimWrite(request, ctx, user)
  if claimed.isNone:
    return
  let w = claimed.get
  var row: Option[Row]
  auditedWrite(proc(tx: Db, conn: DbConn) =
    row = tx.queryOne(
      """insert into session.sessions
         (community_id, title, session_date, start_time, slot_minutes, status,
          source, scoring_preset, scoring_rules)
         values ($1, $2, $3::date, $4::time, $5, 'draft', 'manual', $6,
                 $7::jsonb)
         returning id, title, session_date::text as session_date, status""",
      @[textParam(ctx.communityId), textParam(title), textParam(date),
        textParam(startTime), intParam(slot.int64), textParam(presetId),
        textParam($sessionScoring.rulesJson(chosen.get))])
    if row.isSome:
      auditConn(conn, "session.create", ctx, user, "session",
        row.get.get("id"),
        %*{"title": row.get.get("title"), "date": row.get.get("session_date"),
            "status": row.get.get("status")}))
  if row.isNone:
    # Nothing was written, so release the key instead of leaving it owned until
    # the TTL turns every retry into a 409.
    w.release()
    problem(request, 400, "INVALID_SESSION", "cannot create session")
    return
  let created = %*{
    "id": row.get.get("id"),
    "title": row.get.get("title"),
    "date": row.get.get("session_date"),
    "status": row.get.get("status"),
  }
  w.complete(201, created)
  jsonResponse(request, 201, created)

proc pageParams(request: Request, snapshot: Snapshot): tuple[limit, offset: int] =
  ## One clamp for every list route: a value outside the range is pulled to the
  ## nearest bound instead of silently falling back, so the page a caller asks
  ## for is the page it gets.
  let fallback = snapshot.intValue(%*{}, keyApiPageSizeDefault)
  let pageSizeMax = snapshot.intValue(%*{}, keyApiPageSizeMax)
  var requested = fallback
  let limitParam = request.queryParams["limit"]
  if limitParam.len > 0:
    try:
      requested = parseInt(limitParam)
    except ValueError:
      requested = fallback
  result.limit = max(1, min(requested, pageSizeMax))
  let offsetMax = snapshot.intValue(%*{}, keyApiPageOffsetMax)
  let offsetParam = request.queryParams["offset"]
  if offsetParam.len > 0:
    try:
      result.offset = max(0, min(parseInt(offsetParam), offsetMax))
    except ValueError:
      result.offset = 0

proc pagedJson(request: Request, items: JsonNode, total, limit,
               offset: int) =
  ## The one page envelope every collection route answers. `nextCursor` is the
  ## next offset when more rows remain, and an empty string on the last page,
  ## so a client follows the same rule on every list.
  let nextCursor =
    if offset + items.len < total: $(offset + limit) else: ""
  jsonResponse(request, 200, %*{"items": items, "total": total,
    "nextCursor": nextCursor})

proc sessionStatusFilter(request: Request): string =
  ## An unknown status is not a filter. The route validates against the column
  ## check constraint so a typo narrows nothing instead of answering 400 for a
  ## read the caller already knows how to retry.
  let status = request.queryParams["status"].strip()
  if status in ["draft", "locked", "published", "completed", "archived"]:
    status
  else:
    ""

proc listSessions(request: Request, ctx: CommunityContext,
                  snapshot: Snapshot) =
  ## One page, never a silently truncated history: the caller pages with
  ## `offset` and filters on the server, so a search is not limited to the
  ## newest page.
  let (limit, offset) = pageParams(request, snapshot)
  var date = request.queryParams["date"]
  if date.len > 0 and not validSessionDate(date):
    date = ""
  let q = request.queryParams["q"].strip()
  let status = sessionStatusFilter(request)
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
         and ($3 = '' or strpos(lower(s.title), lower($3)) > 0)
         and ($4 = '' or s.status = $4)
       order by s.session_date desc, s.updated_at desc
       limit $5 offset $6""",
    @[textParam(ctx.communityId), textParam(date), textParam(q),
      textParam(status), intParam(limit.int64), intParam(offset.int64)]):
    items.add(%*{"id": row.get("id"), "title": row.get("title"),
      "date": row.get("session_date"), "status": row.get("status"),
      "version": parseInt(row.get("version")),
      "playerCount": parseInt(row.get("player_count")),
      "totalGames": parseInt(row.get("total_games"))})
  let totalRow = application.db.queryOne(
    """select count(*)::int as total from session.sessions s
       where s.community_id = $1::uuid
         and ($2 = '' or s.session_date = nullif($2, '')::date)
         and ($3 = '' or strpos(lower(s.title), lower($3)) > 0)
         and ($4 = '' or s.status = $4)""",
    @[textParam(ctx.communityId), textParam(date), textParam(q),
      textParam(status)])
  let total = if totalRow.isSome: parseInt(totalRow.get.get("total")) else: 0
  pagedJson(request, items, total, limit, offset)

proc createShare(request: Request, ctx: CommunityContext, user: AuthUser,
                 sessionId: string, snapshot: Snapshot) =
  let session = application.db.queryOne(
    """select id, status from session.sessions
       where id = $1 and community_id = $2""",
    @[textParam(sessionId), textParam(ctx.communityId)])
  if session.isNone:
    problem(request, 404, "NOT_FOUND", "session not found")
    return
  # A code hands the session to anyone holding it, so it may only name a
  # session the community has approved. A draft would publish an unfinished
  # schedule and standings for the whole TTL.
  let status = session.get.get("status")
  if not shareStore.shareable(status):
    problem(request, 409, "SESSION_NOT_SHAREABLE",
      "session status is " & status & "; only an approved session is shareable")
    return
  # Issuing a link revokes the previous one in the same transaction, so its
  # watchers and their tickets go too.
  let previous = application.db.queryOne(
    """select id from session.links
       where community_id = $1::uuid and session_id = $2::uuid
         and revoked_at is null""",
    @[textParam(ctx.communityId), textParam(sessionId)])
  var code = ""
  auditedWrite(proc(tx: Db, conn: DbConn) =
    code = shareStore.issue(tx, application.keyring,
      ctx.communityId, sessionId, user.id,
      snapshot.intValue(%*{}, keyShareLinkTtlDays))
    auditConn(conn, "share.issue", ctx, user, "session", sessionId,
      %*{"sessionId": sessionId}))
  if previous.isSome:
    application.hub.revokeShare(previous.get.get("id"))
  jsonResponse(request, 201, %*{"code": code, "sessionId": sessionId})

proc deleteShareLink(request: Request, ctx: CommunityContext, user: AuthUser,
                     sessionId: string) =
  var revoked: seq[string] = @[]
  auditedWrite(proc(tx: Db, conn: DbConn) =
    revoked = shareStore.revokeLive(tx, ctx.communityId, sessionId)
    if revoked.len > 0:
      auditConn(conn, "share.revoke", ctx, user, "session", sessionId,
        %*{"sessionId": sessionId}))
  if revoked.len == 0:
    problem(request, 404, "NOT_FOUND", "no live share link")
    return
  for linkId in revoked:
    application.hub.revokeShare(linkId)
  send(request, 204)

proc issueSessionTicket(request: Request, ctx: CommunityContext, user: AuthUser,
                        sessionId: string, snapshot: Snapshot) =
  ## Read access is enough: any member may watch. The ticket is bound to the
  ## session row, so a foreign-community id is a 404 before anything is issued.
  let session = application.db.queryOne(
    "select id from session.sessions where id = $1 and community_id = $2",
    @[textParam(sessionId), textParam(ctx.communityId)])
  if session.isNone:
    problem(request, 404, "NOT_FOUND", "session not found")
    return
  let ttl = snapshot.intValue(%*{}, keyWsTicketTtlSeconds)
  let ticket = wsTicket.issueSession(application.db, user.id, sessionId, ttl)
  jsonResponse(request, 200, %*{"ticket": ticket, "expiresIn": ttl})

proc shareKeyProblemLine*(linkId, requestId: string): string =
  ## The line a key problem writes. Pure so a suite can assert its fields
  ## without racing the worker thread that owns stdout.
  renderLog("error", "share link key missing",
    [("linkId", linkId), ("request_id", requestId)])

proc shareKeyUnavailable(request: Request,
                         error: ref shareStore.ShareKeyProblem) =
  ## One refusal for a live row whose key this process does not hold. 503, not
  ## 404: the row exists and the operator has to restore the key, so "no link"
  ## would send them to issue a new one. The link id is logged, never the code.
  recordShareKeyProblem()
  writeLogLine shareKeyProblemLine(error.linkId, currentRequestId())
  problem(request, 503, "UNAVAILABLE", "share link key is not available")

proc issueShareTicket(request: Request, code: string, snapshot: Snapshot) =
  ## Anonymous path: the share limiter has already run in `route`, before this
  ## insert. Only a `share` channel ticket is ever minted here.
  let found = shareStore.resolve(application.db, application.keyring, code)
  if found.isNone:
    problem(request, 404, "NOT_FOUND", "link not found")
    return
  let ttl = snapshot.intValue(%*{}, keyWsTicketTtlSeconds)
  let ticket = wsTicket.issueShare(application.db, found.get.linkId, ttl)
  jsonResponse(request, 200, %*{"ticket": ticket, "expiresIn": ttl},
    [("X-Robots-Tag", "noindex")])

proc ifMatch(request: Request): Option[int] =
  ## OCC precondition. Missing is 428, not 400: the client must opt in.
  ## Only a strong validator is accepted. `W/"7"` says the entity may not be
  ## byte-identical, so honouring it would let a downgraded validator overwrite
  ## a concurrent edit the precondition exists to reject. `*` names no version,
  ## so it is refused like any other value this API cannot compare (400 via
  ## `requireIfMatch`), rather than treated as "any".
  var text = request.headers["If-Match"].strip()
  if text.len == 0:
    return none(int)
  if text.len >= 2 and text[0 .. 1].toLowerAscii() == "w/":
    return none(int)
  if text[0] == '"':
    if text.len < 2 or text[^1] != '"':
      return none(int)
    text = text[1 .. ^2]
  try:
    some(parseInt(text))
  except ValueError:
    none(int)

proc requireIfMatch(request: Request): Option[int] =
  ## A header that is present but unparsable is a client bug, not a request to
  ## skip the precondition: only a missing one is 428.
  if request.headers["If-Match"].strip().len == 0:
    problem(request, 428, "PRECONDITION_REQUIRED", "If-Match is required")
    return none(int)
  result = ifMatch(request)
  if result.isNone:
    problem(request, 400, "INVALID_PRECONDITION",
      "If-Match must be a version number")

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

proc patchSession(request: Request, ctx: CommunityContext, user: AuthUser,
                  sessionId: string, snapshot: Snapshot) =
  let version = requireIfMatch(request)
  if version.isNone: return
  let claimed = claimWrite(request, ctx, user, "session/" & sessionId)
  if claimed.isNone:
    return
  let w = claimed.get
  var patchBody: SessionPatch
  try:
    patchBody = sessionWrite.parsePatch(bodyJson(request, snapshot))
  except ValueError as error:
    w.release()
    logWarn("session patch rejected",
      [("error", error.msg), ("path", request.path)])
    problem(request, 400, "INVALID_PATCH", error.msg)
    return
  # The patch used to hand raw strings to `::date` / `::time`: a bad day became
  # a 500 and a loose "9:00" was normalised where create rejects it.
  if patchBody.date.isSome and not validSessionDate(patchBody.date.get):
    w.release()
    problem(request, 400, "INVALID_PATCH", "date must be a real YYYY-MM-DD day")
    return
  if patchBody.startTime.isSome:
    let clock = normalizeClockTime(patchBody.startTime.get)
    if clock.isNone:
      w.release()
      problem(request, 400, "INVALID_PATCH",
        "startTime must be HH:MM or HH:MM:SS")
      return
    patchBody.startTime = clock
  if patchBody.scoringPreset.isSome:
    # The id is resolved against the current list; a removed preset cannot be
    # chosen even though an old session keeps its own snapshot.
    let chosen = findPreset(snapshot, patchBody.scoringPreset.get)
    if chosen.isNone:
      w.release()
      problem(request, 400, "INVALID_PRESET", "unknown scoring preset")
      return
    patchBody.scoringRules = some(chosen.get)
  var result: sessionWrite.WriteResult
  auditedWrite(proc(tx: Db, conn: DbConn) =
    result = sessionWrite.patch(tx, ctx.communityId, sessionId,
      version.get, patchBody)
    if result.status == wsOk:
      auditConn(conn, "session.patch", ctx, user, "session", sessionId,
        result.record))
  case result.status
  of wsOk:
    w.complete(200, result.record)
    application.hub.sessionChanged(sessionId, result.record["version"].getInt())
    jsonResponse(request, 200, result.record,
      [("ETag", "\"" & $result.record["version"].getInt() & "\"")])
  of wsStale:
    w.release()
    problem(request, 412, "STALE_VERSION", "session changed since If-Match")
  of wsNotFound:
    w.release()
    problem(request, 404, "NOT_FOUND", "session not found")
  of wsInvalid:
    w.release()
    problem(request, 400, "INVALID_PATCH", "cannot apply patch")
  of wsPresetLocked:
    w.release()
    problem(request, 409, "PRESET_LOCKED",
      "clear the recorded sets before changing the format")
  of wsUnscoredGames:
    # Only `setLock` reads the games, so a patch cannot produce this state; the
    # branch keeps the case total.
    w.release()
    problem(request, 409, "INVALID_PATCH", "cannot apply patch")

proc swapSession(request: Request, ctx: CommunityContext, user: AuthUser,
                 sessionId: string,
                    snapshot: Snapshot) =
  ## Session-level OCC: an If-Match version, one transaction, then the same
  ## `session.changed` broadcast every other schedule write sends.
  let version = requireIfMatch(request)
  if version.isNone: return
  let claimed = claimWrite(request, ctx, user, "session/" & sessionId & "/swap")
  if claimed.isNone:
    return
  let w = claimed.get
  var body: JsonNode
  if not jsonBody(request, snapshot, body):
    w.release()
    return
  var result: sessionSwap.SwapOutcome
  auditedWrite(proc(tx: Db, conn: DbConn) =
    result = sessionSwap.swapMembers(tx, ctx.communityId,
      sessionId, version.get, sessionSwap.parseSwap(body))
    if result.status == sessionSwap.swOk:
      let record = %*{"version": result.version,
        "status": result.sessionStatus}
      auditConn(conn, "session.swap", ctx, user, "session", sessionId,
        record))
  case result.status
  of sessionSwap.swOk:
    let record = %*{"version": result.version, "status": result.sessionStatus}
    w.complete(200, record)
    application.hub.sessionChanged(sessionId, result.version)
    jsonResponse(request, 200, record,
      [("ETag", "\"" & $result.version & "\"")])
  of sessionSwap.swInvalid:
    w.release()
    problem(request, 400, "INVALID_SWAP", result.detail)
  of sessionSwap.swStale:
    w.release()
    problem(request, 412, "STALE_VERSION", "session changed since If-Match")
  of sessionSwap.swNotFound:
    w.release()
    let detail = if result.detail.len > 0: result.detail else: "session not found"
    problem(request, 404, "NOT_FOUND", detail)
  of sessionSwap.swLocked:
    w.release()
    problem(request, 403, "FORBIDDEN", "session is locked")

proc ratingParamsFor(ctx: CommunityContext,
                     snapshot: Snapshot): ratingDomain.RatingParams =
  ratingParams.loadRatingParams(snapshot, ctx.settings)

proc setSessionLock(request: Request, ctx: CommunityContext, user: AuthUser,
                    sessionId: string, locked: bool, snapshot: Snapshot) =
  let version = requireIfMatch(request)
  if version.isNone: return
  # A sign-off freezes the source: unlocking withdraws its event, and re-locking
  # used to rewrite `approved_at`/`approved_by`, so a host could re-stamp a
  # result an admin had approved. Both directions refuse now.
  if ratingIngest.sourceFinalized(application.db, ctx.communityId, sessionId):
    problem(request, 403, "FORBIDDEN", "rating source is finalized")
    return
  var outcome: sessionWrite.WriteResult
  var removed = 0
  var params: ratingDomain.RatingParams
  if locked:
    params = ratingParamsFor(ctx, snapshot)
  auditedWrite(proc(tx: Db, conn: DbConn) =
    outcome = sessionWrite.setLock(tx, ctx.communityId, sessionId,
      user.id, version.get, locked)
    if outcome.status == wsOk:
      if locked:
        discard ratingIngest.ingestSession(tx, ctx.communityId,
          sessionId, params)
      else:
        removed = ratingIngest.revertSource(tx, ctx.communityId, sessionId)
      auditConn(conn, (if locked: "session.lock" else: "session.unlock"),
        ctx, user, "session", sessionId, outcome.record))
  case outcome.status
  of wsOk:
    # Approval is the rating gate: locking rates the session now, unlocking
    # withdraws what it contributed. The withdraw is immediate; the ledger
    # replay and the badge reconciliation that follow are queued, because a
    # full rebuild must not run under this request's connection and advisory
    # lock. The response record is unchanged, only the derived board lags by
    # one worker pass.
    if locked:
      discard application.ratingJobs.enqueue(ratingJobs.jkReconcile,
        ctx.communityId)
    elif removed > 0:
      discard application.ratingJobs.enqueue(ratingJobs.jkRebuild,
        ctx.communityId)
    jsonResponse(request, 200, outcome.record,
      [("ETag", "\"" & $outcome.record["version"].getInt() & "\"")])
  of wsStale:
    problem(request, 412, "STALE_VERSION", "session changed since If-Match")
  of wsNotFound:
    problem(request, 404, "NOT_FOUND", "session not found")
  of wsInvalid:
    problem(request, 400, "INVALID_PATCH", "cannot lock session")
  of wsPresetLocked:
    problem(request, 409, "PRESET_LOCKED", "session has recorded sets")
  of wsUnscoredGames:
    problem(request, 409, "INVALID_PATCH",
      "a played game has no score; enter the score or unmark the game")
  if outcome.status == wsOk:
    application.hub.sessionChanged(sessionId,
      outcome.record["version"].getInt())

proc getCommunitySettings(request: Request, ctx: CommunityContext,
                          snapshot: Snapshot) =
  let settings = ctx.settings
  jsonResponse(request, 200, %*{
    "values": visibleSettings(settings),
    "effective": effectiveConfig(snapshot, settings),
  })

proc patchCommunitySettings(request: Request, ctx: CommunityContext,
                            user: AuthUser, snapshot: Snapshot) =
  var body: JsonNode
  try:
    body = bodyJson(request, snapshot)
  except ValueError:
    problem(request, 400, "INVALID_BODY", "settings patch must be JSON")
    return
  let result = applyPatch(application.db, snapshot, ctx.communityId,
    user.id, body, currentRequestId(), $ctx.role)
  case result.outcome
  of soOk:
    jsonResponse(request, 200,
      %*{"values": visibleSettings(currentSettings(application.db,
        ctx.communityId))})
  of soUnknownKey:
    problem(request, 400, "UNKNOWN_CONFIG_KEY", result.detail & ": " & result.key)
  of soPlatformScope:
    problem(request, 400, "PLATFORM_CONFIG_KEY", result.detail & ": " & result.key)
  of soOutOfCeiling:
    problem(request, 400, "OVERRIDE_TOO_HIGH", result.detail & ": " & result.key)
  of soInvalidType:
    problem(request, 400, "INVALID_CONFIG_VALUE", result.detail & ": " & result.key)

proc directory(request: Request, snapshot: Snapshot) =
  ## Public listing. Outsiders only see communities that opted in; a member also
  ## sees their own. Entries carry the slug and the name, nothing else.
  let user = currentUser(request, snapshot)
  let items = communityStore.directory(application.db,
    (if user.isSome: some(user.get.id) else: none(string)),
    snapshot.boolValue(%*{}, keyCommunityDirectoryEnabled),
    $keyCommunityDirectoryEnabled)
  jsonResponse(request, 200, %*{"items": items})

proc createInvite(request: Request, ctx: CommunityContext, user: AuthUser,
                  snapshot: Snapshot) =
  var body: JsonNode
  if not jsonBody(request, snapshot, body):
    return
  let email = optStr(body, "email")
  if not communityDomain.validEmail(email):
    problem(request, 400, "INVALID_EMAIL", "a valid email is required")
    return
  let role = optStr(body, "role", "member")
  var parsed: Role
  try:
    parsed = parseRole(role)
  except ValueError:
    problem(request, 400, "INVALID_ROLE", "role must be member, host or admin")
    return
  let ttl = snapshot.intValue(ctx.settings, keyCommunityInviteTtlDays)
  var token = ""
  auditedWrite(proc(tx: Db, conn: DbConn) =
    token = inviteStore.create(tx, ctx.communityId,
      sha256Hex(email.strip().toLowerAscii()), parsed, user.id, ttl)
    auditConn(conn, "community.invite", ctx, user, "community",
      ctx.communityId, %*{"role": $parsed}))
  jsonResponse(request, 201, %*{"token": token, "expiresInDays": ttl, "role": $parsed})

proc acceptInvite(request: Request, token: string,
                    snapshot: Snapshot) =
  let user = requireUser(request, snapshot)
  if user.isNone:
    return
  var result: inviteStore.AcceptResult
  auditedWrite(proc(tx: Db, conn: DbConn) =
    result = inviteStore.accept(tx, token, user.get.id,
      user.get.emailHash)
    if result.outcome == aoOk:
      auditConn(conn, "community.join", result.communityId, user.get,
        "community", result.communityId, %*{"role": result.role},
        result.role))
  case result.outcome
  of aoOk:
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

proc requestJoin(request: Request, slug: string, snapshot: Snapshot) =
  ## Anti-enumeration: an unknown slug, a community that is not accepting and an
  ## already-pending request all return the same 202 body.
  let user = currentUser(request, snapshot)
  if user.isSome:
    # Per account per window: a repeated submission is a script, not a person,
    # and the anonymous path never reaches the store anyway.
    if quota(request, snapshot, "join",
        requestIdentity(request, snapshot, clientIp(request, trustedProxies())),
        snapshot.intValue(%*{}, keySecurityJoinRequestRate)):
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
        boolParam(snapshot.boolValue(%*{}, keyCommunityJoinRequestsEnabled))])
    else:
      none(Row)
  if row.isSome and row.get.get("enabled") == "t" and user.isSome:
    let requester = user.get
    auditedWrite(proc(tx: Db, conn: DbConn) =
      let created = joinRequestStore.request(tx, row.get.get("id"),
        requester.id)
      if created:
        # The request itself is a self-service write; record it without the
        # community context the requester does not have yet.
        auditConn(conn, "community.join.requested", row.get.get("id"),
          requester, "user", requester.id, %*{"status": "pending"},
          role = "member"))
  jsonResponse(request, 202, %*{"status": "accepted"})

proc listJoinRequests(request: Request, ctx: CommunityContext,
                      snapshot: Snapshot) =
  let (limit, offset) = pageParams(request, snapshot)
  var items = newJArray()
  for entry in joinRequestStore.listPending(application.db, ctx.communityId,
                                            limit, offset):
    items.add(%*{"id": entry.id, "userId": entry.userId,
      "displayName": entry.displayName, "createdAt": entry.createdAt})
  pagedJson(request, items,
    joinRequestStore.countPending(application.db, ctx.communityId), limit,
    offset)

proc decideJoinRequest(request: Request, ctx: CommunityContext, user: AuthUser,
                       requestId: string,
                    snapshot: Snapshot) =
  var body: JsonNode
  if not jsonBody(request, snapshot, body):
    return
  let decision = optStr(body, "decision")
  if decision notin ["approve", "reject"]:
    problem(request, 400, "INVALID_DECISION", "decision must be approve or reject")
    return
  let role = optStr(body, "role", "member")
  var parsed: Role
  try:
    parsed = parseRole(role)
  except ValueError:
    problem(request, 400, "INVALID_ROLE", "role must be member, host or admin")
    return
  let approve = decision == "approve"
  var decided = false
  auditedWrite(proc(tx: Db, conn: DbConn) =
    decided = joinRequestStore.decide(tx, ctx.communityId, requestId,
      user.id, parsed, approve)
    if decided:
      auditConn(conn,
        (if approve: "community.join.approved" else: "community.join.rejected"),
        ctx.communityId, user, "join_request", requestId, %*{"role": $parsed}))
  if not decided:
    problem(request, 404, "NOT_FOUND", "pending request not found")
    return
  jsonResponse(request, 200, %*{"status": if approve: "approved" else: "rejected"})

proc listPendingClaims(request: Request, ctx: CommunityContext,
                       snapshot: Snapshot) =
  let (limit, offset) = pageParams(request, snapshot)
  var items = newJArray()
  for entry in playerClaim.listPending(application.db, ctx.communityId,
                                       limit, offset):
    items.add(%*{"claimId": entry.claimId, "playerId": entry.playerId,
      "playerName": entry.playerName, "userId": entry.userId,
      "displayName": entry.displayName, "createdAt": entry.createdAt})
  pagedJson(request, items,
    playerClaim.countPending(application.db, ctx.communityId), limit, offset)

proc listMembers(request: Request, ctx: CommunityContext,
                 snapshot: Snapshot) =
  let (limit, offset) = pageParams(request, snapshot)
  var items = newJArray()
  for member in membershipStore.list(application.db, ctx.communityId, limit,
                                     offset):
    items.add(%*{"userId": member.userId, "displayName": member.displayName,
      "role": member.role, "joinedAt": member.joinedAt})
  pagedJson(request, items,
    membershipStore.count(application.db, ctx.communityId), limit, offset)

proc patchMemberRole(request: Request, ctx: CommunityContext, user: AuthUser,
                     targetId: string,
                    snapshot: Snapshot) =
  var body: JsonNode
  if not jsonBody(request, snapshot, body):
    return
  let role = optStr(body, "role")
  var parsed: Role
  try:
    parsed = parseRole(role)
  except ValueError:
    problem(request, 400, "INVALID_ROLE", "role must be member, host or admin")
    return
  var previous: Option[Row]
  var outcome = membershipStore.mwNotFound
  auditedWrite(proc(tx: Db, conn: DbConn) =
    # Read before the write: this is the role the change replaces.
    previous = tx.queryOne(membershipSql.memberRoleSql,
      @[textParam(ctx.communityId), textParam(targetId)])
    outcome = membershipStore.setRoleChecked(tx, ctx.communityId,
      targetId, parsed)
    if outcome == membershipStore.mwOk:
      # The old role is what makes a role change auditable; `role` alone cannot
      # tell a promotion from a demotion.
      auditConn(conn, "community.member.role", ctx, user, "user", targetId,
        %*{"fromRole": if previous.isSome: previous.get.get("role") else: "",
           "toRole": $parsed}))
  case outcome
  of membershipStore.mwLastAdmin:
    problem(request, 409, "LAST_ADMIN", "promote another admin first")
    return
  of membershipStore.mwNotFound:
    problem(request, 404, "NOT_FOUND", "member not found")
    return
  of membershipStore.mwOk:
    discard
  jsonResponse(request, 200, %*{"userId": targetId, "role": $parsed})

proc removeMember(request: Request, ctx: CommunityContext, user: AuthUser,
                  targetId: string) =
  var outcome = membershipStore.mwNotFound
  auditedWrite(proc(tx: Db, conn: DbConn) =
    outcome = membershipStore.removeChecked(tx, ctx.communityId, targetId)
    if outcome == membershipStore.mwOk:
      auditConn(conn, "community.member.remove", ctx, user, "user", targetId))
  case outcome
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
  send(request, 204)

proc scoringPresetsJson(snapshot: Snapshot): JsonNode =
  ## Read-only reference data for the wizard. `mode` is internal, so it is not
  ## part of the public shape.
  result = newJArray()
  for preset in scoringPresets(snapshot):
    var item = sessionScoring.rulesJson(preset)
    item.delete("mode")
    result.add(item)

proc communityConfig(request: Request, ctx: CommunityContext,
                     snapshot: Snapshot) =
  ## Effective registry values for this community, with the source of each one.
  jsonResponse(request, 200,
    %*{"effective": effectiveConfig(snapshot, ctx.settings),
       "scoringPresets": scoringPresetsJson(snapshot)})

proc tierParam(request: Request): string =
  ## `+` means space in a form-encoded query, so a hand-written `?tier=C+`
  ## arrives as "C ". A tier the ladder does not know is ignored instead of
  ## silently emptying the board.
  let raw = request.queryParams["tier"]
  if raw.strip().len == 0:
    return ""
  # Try the plus-restored spelling first: a real tier never contains a space.
  for candidate in [raw.replace(' ', '+'), raw]:
    try:
      return $playerDomain.parseTier(candidate.strip())
    except ValueError:
      discard
  ""

proc listPlayersRoute(request: Request, ctx: CommunityContext,
                      userId: string, snapshot: Snapshot) =
  # `mine=1` backs the "my statistics" shortcut: the account asks for the one
  # player it owns instead of walking the roster and matching ids.
  if request.queryParams["mine"] == "1":
    let owned = playerStore.ownedBy(application.db, ctx.communityId, userId)
    var body = newJArray()
    if owned.isSome:
      body.add(owned.get)
    jsonResponse(request, 200, %*{"items": body})
    return
  let items = playerStore.list(application.db, ctx.communityId,
    pageParams(request, snapshot).limit, request.queryParams["cursor"],
    tierParam(request), request.queryParams["q"])
  var body = newJArray()
  for item in items:
    body.add(item)
  jsonResponse(request, 200, %*{"items": body})

proc withAliases(player: JsonNode, aliases: seq[string]): JsonNode =
  result = player
  var list = newJArray()
  for alias in aliases:
    list.add(%alias)
  result["aliases"] = list

proc createPlayerRoute(request: Request, ctx: CommunityContext, user: AuthUser,
                    snapshot: Snapshot) =
  var body: JsonNode
  if not jsonBody(request, snapshot, body):
    return
  let name = optStr(body, "name")
  let gender = optStr(body, "gender", "M")
  let tier = optStr(body, "tier")
  let problems = playerDomain.checkCreate(name, gender, tier)
  if problems.len > 0:
    problem(request, 400, "INVALID_PLAYER", $problems[0])
    return
  var aliases: seq[string] = @[]
  if body.hasKey("aliases"):
    try:
      aliases = playerDomain.parseAliases(body["aliases"])
    except ValueError as error:
      logWarn("player aliases rejected",
        [("error", error.msg), ("path", request.path)])
      problem(request, 400, "INVALID_PLAYER", error.msg)
      return
    if not playerDomain.aliasesValid(aliases):
      problem(request, 400, "INVALID_ALIAS", "aliases must be distinct non-empty names")
      return
  var result: playerStore.CreateResult
  var aliasTaken = false
  try:
    auditedWrite(proc(tx: Db, conn: DbConn) =
      result = playerStore.create(tx, ctx.communityId,
        playerDomain.normalizeName(name), gender.toUpperAscii(),
        if tier.len > 0: $playerDomain.parseTier(tier) else: "")
      if result.status == pcOk:
        let playerId = result.player["id"].getStr()
        if aliases.len > 0 and
           not playerStore.setAliases(tx, ctx.communityId, playerId, aliases):
          # The insert and its aliases share the transaction, so a taken alias
          # rolls both back instead of leaving a half-created player.
          aliasTaken = true
          raise newException(WriteRefusal, "alias taken")
        auditConn(conn, "player.create", ctx, user, "player", playerId,
          %*{"name": result.player["name"]}))
  except WriteRefusal:
    discard
  if aliasTaken:
    problem(request, 409, "ALIAS_TAKEN", "an alias is already used by another player")
    return
  case result.status
  of pcDuplicate:
    problem(request, 409, "PLAYER_EXISTS", "a player with this name already exists")
  of pcInvalid:
    problem(request, 400, "INVALID_PLAYER", "cannot create player")
  of pcOk:
    let playerId = result.player["id"].getStr()
    jsonResponse(request, 201, withAliases(result.player,
      playerStore.aliases(application.db, ctx.communityId, playerId)))

proc getPlayerRoute(request: Request, ctx: CommunityContext, user: AuthUser,
                    playerId: string) =
  let player = playerStore.get(application.db, ctx.communityId, playerId)
  if player.isNone:
    problem(request, 404, "NOT_FOUND", "player not found")
    return
  var body = withAliases(player.get,
    playerStore.aliases(application.db, ctx.communityId, playerId))
  # The claim action is refused server-side when the viewer already owns a
  # player here, so the page needs to know before offering the button.
  body["viewerOwnsPlayer"] =
    %playerClaim.ownsPlayer(application.db, ctx.communityId, user.id)
  jsonResponse(request, 200, body)

proc patchPlayerRoute(request: Request, ctx: CommunityContext, user: AuthUser,
                      playerId: string,
                    snapshot: Snapshot) =
  var patch: playerDomain.PlayerPatch
  try:
    patch = playerDomain.parsePatch(bodyJson(request, snapshot))
  except ValueError as error:
    logWarn("player patch rejected",
      [("error", error.msg), ("path", request.path)])
    problem(request, 400, "INVALID_PLAYER", error.msg)
    return
  var aliases: seq[string] = @[]
  if patch.aliases.isSome:
    aliases = patch.aliases.get
    if not playerDomain.aliasesValid(aliases):
      problem(request, 400, "INVALID_ALIAS", "aliases must be distinct non-empty names")
      return
  var result: playerStore.PatchResult
  auditedWrite(proc(tx: Db, conn: DbConn) =
    result = playerStore.patch(tx, ctx.communityId, playerId, patch)
    if result.status == psOk and not result.aliasTaken:
      auditConn(conn, "player.patch", ctx, user, "player", playerId,
        %*{"name": result.player["name"]}))
  case result.status
  of psOk:
    if result.aliasTaken:
      problem(request, 409, "ALIAS_TAKEN", "an alias is already used by another player")
      return
    jsonResponse(request, 200, withAliases(result.player,
      playerStore.aliases(application.db, ctx.communityId, playerId)))
  of psDuplicate:
    problem(request, 409, "PLAYER_EXISTS", "a player with this name already exists")
  of psNotFound:
    problem(request, 404, "NOT_FOUND", "player not found")

proc mergePlayerRoute(request: Request, ctx: CommunityContext, user: AuthUser,
                        targetId: string,
                    snapshot: Snapshot) =
  var body: JsonNode
  if not jsonBody(request, snapshot, body):
    return
  if not body.hasKey("sourcePlayerId") or body["sourcePlayerId"].kind != JString:
    problem(request, 400, "INVALID_BODY", "sourcePlayerId is required")
    return
  let sourceId = body["sourcePlayerId"].getStr()
  var outcome: playerMerge.MergeOutcome
  auditedWrite(proc(tx: Db, conn: DbConn) =
    outcome = playerMerge.merge(tx, ctx.communityId, targetId,
      sourceId, user.id)
    if outcome.error == playerMerge.meOk:
      auditConn(conn, "player.merge", ctx, user, "player", targetId,
        %*{"sourcePlayerId": sourceId,
          "rowsMoved": outcome.result.aliasesMoved + outcome.result.claimsMoved +
            outcome.result.deltasMoved + outcome.result.snapshotsMoved +
            outcome.result.achievementsMoved + outcome.result.pairsMoved +
            outcome.result.ratingStateMoved + outcome.result.sessionsMoved +
            outcome.result.gamesMoved + outcome.result.skipsMoved +
            outcome.result.teamPlayersMoved}))
  case outcome.error
  of playerMerge.meOk:
    jsonResponse(request, 200, %*{
      "targetPlayerId": outcome.result.targetPlayerId,
      "sourcePlayerId": outcome.result.sourcePlayerId,
      "aliasesMoved": outcome.result.aliasesMoved,
      "claimsMoved": outcome.result.claimsMoved,
      "deltasMoved": outcome.result.deltasMoved,
      "snapshotsMoved": outcome.result.snapshotsMoved,
      "achievementsMoved": outcome.result.achievementsMoved,
      "pairsMoved": outcome.result.pairsMoved,
      "ratingStateMoved": outcome.result.ratingStateMoved,
      "sessionsMoved": outcome.result.sessionsMoved,
      "gamesMoved": outcome.result.gamesMoved,
      "skipsMoved": outcome.result.skipsMoved,
      "teamPlayersMoved": outcome.result.teamPlayersMoved})
  of playerMerge.mePlayerNotFound:
    problem(request, 404, "NOT_FOUND", "player not found")
  of playerMerge.meSamePlayer:
    problem(request, 400, "SAME_PLAYER", "source and target must differ")
  of playerMerge.mePairInUse:
    problem(request, 409, "MERGE_CONFLICT",
      "a tournament pair of both players is already used by a match")
  of playerMerge.meSessionCollision:
    problem(request, 409, "MERGE_SESSION_CONFLICT",
      "both players appear in the same game; edit that game first")
  of playerMerge.mePairCollision:
    problem(request, 409, "MERGE_PAIR_CONFLICT",
      "both players already have a pair with the same partner")
  of playerMerge.meConflict:
    problem(request, 409, "MERGE_CONFLICT", "players cannot be merged")

proc deletePlayerRoute(request: Request, ctx: CommunityContext, user: AuthUser,
                       playerId: string) =
  var removed = false
  auditedWrite(proc(tx: Db, conn: DbConn) =
    removed = playerStore.remove(tx, ctx.communityId, playerId)
    if removed:
      auditConn(conn, "player.delete", ctx, user, "player", playerId))
  if not removed:
    problem(request, 404, "NOT_FOUND", "player not found")
    return
  send(request, 204)

proc claimProblem(request: Request, error: playerClaim.ClaimError) =
  case error
  of cePlayerNotFound:
    problem(request, 404, "NOT_FOUND", "player not found")
  of ceAlreadyPending:
    problem(request, 409, "CLAIM_PENDING", "a claim for this player is pending")
  of ceAlreadyClaimed:
    problem(request, 409, "CLAIMED", "this player already has an owner")
  of ceClaimantOwnsPlayer:
    problem(request, 409, "CLAIMANT_OWNS_PLAYER",
      "this member already has a player in this community")
  of ceClaimNotFound:
    problem(request, 404, "NOT_FOUND", "claim not found")
  of ceSelfDecision:
    problem(request, 403, "SELF_DECISION", "you cannot decide your own claim")
  of ceConflict:
    problem(request, 409, "CLAIM_CONFLICT", "claim changed after it was read")
  of ceOk:
    discard

proc listClaimsRoute(request: Request, ctx: CommunityContext, user: AuthUser,
                     playerId: string, snapshot: Snapshot) =
  ## Members see the claim trail but not who else applied or who decided:
  ## only a member's own claim stays identifiable, so the page can still say
  ## they are waiting. Hosts and admins need the full record to act on it.
  if playerStore.get(application.db, ctx.communityId, playerId).isNone:
    problem(request, 404, "NOT_FOUND", "player not found")
    return
  let privileged = ctx.role in [rHost, rAdmin]
  let (limit, offset) = pageParams(request, snapshot)
  var items = newJArray()
  for claim in playerClaim.list(application.db, ctx.communityId, playerId,
                                limit, offset):
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
  pagedJson(request, items,
    playerClaim.count(application.db, ctx.communityId, playerId), limit, offset)

proc submitClaim(request: Request, ctx: CommunityContext, user: AuthUser,
                 playerId: string) =
  var result = ceConflict
  auditedWrite(proc(tx: Db, conn: DbConn) =
    result = playerClaim.submit(tx, ctx.communityId, playerId, user.id)
    if result == ceOk:
      auditConn(conn, "player.claim.submitted", ctx, user, "player", playerId))
  if result != ceOk:
    claimProblem(request, result)
    return
  jsonResponse(request, 201, %*{"playerId": playerId, "status": "pending"})

proc decideClaim(request: Request, ctx: CommunityContext, user: AuthUser,
                 playerId, claimId: string,
                    snapshot: Snapshot) =
  var body: JsonNode
  if not jsonBody(request, snapshot, body):
    return
  let action = optStr(body, "action")
  let reason = optStr(body, "reason")

  if action == "release":
    if reason.strip().len == 0:
      problem(request, 400, "REASON_REQUIRED", "releasing someone else needs a reason")
      return
    var released = ceConflict
    auditedWrite(proc(tx: Db, conn: DbConn) =
      let subject = playerClaim.claimOwner(tx, ctx.communityId, playerId,
        claimId)
      if subject.len == 0:
        released = ceClaimNotFound
        return
      released = playerClaim.release(tx, ctx.communityId, playerId,
        user.id, claimId, subject, reason)
      if released == ceOk:
        auditConn(conn, "player.claim.released", ctx, user, "claim", claimId,
          %*{"playerId": playerId, "status": "released"}))
    if released != ceOk:
      claimProblem(request, released)
      return
    jsonResponse(request, 200, %*{"claimId": claimId, "status": "released"})
    return

  let decision = optStr(body, "decision")
  if decision notin ["approve", "reject"]:
    problem(request, 400, "INVALID_DECISION", "decision must be approve or reject")
    return
  var result = ceConflict
  auditedWrite(proc(tx: Db, conn: DbConn) =
    result = playerClaim.decide(tx, ctx.communityId, playerId,
      claimId, user.id, decision == "approve", reason)
    if result == ceClaimantOwnsPlayer:
      # This branch persists a rejection (the second claim for one member), so
      # it must leave a trail even though the request answers 409.
      auditConn(conn, "player.claim.rejected", ctx.communityId, user, "claim",
        claimId, %*{"playerId": playerId, "status": "rejected"})
    elif result == ceOk:
      auditConn(conn,
        (if decision == "approve": "player.claim.approved"
         else: "player.claim.rejected"),
        ctx.communityId, user, "claim", claimId, %*{"playerId": playerId}))
  if result != ceOk:
    claimProblem(request, result)
    return
  jsonResponse(request, 200, %*{"claimId": claimId,
    "status": if decision == "approve": "approved" else: "rejected"})

proc releaseOwnClaim(request: Request, ctx: CommunityContext, user: AuthUser,
                     playerId: string) =
  var claimId = ""
  var released = ceConflict
  auditedWrite(proc(tx: Db, conn: DbConn) =
    claimId = playerClaim.approvedClaimFor(tx, ctx.communityId,
      playerId, user.id)
    if claimId.len == 0:
      return
    released = playerClaim.release(tx, ctx.communityId, playerId,
      user.id, claimId, user.id, "self_released")
    if released == ceOk:
      auditConn(conn, "player.claim.released", ctx, user, "claim", claimId,
        %*{"playerId": playerId, "status": "released"}))
  if claimId.len == 0:
    problem(request, 409, "CLAIM_CONFLICT", "you have no approved claim here")
    return
  if released != ceOk:
    claimProblem(request, released)
    return
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
  jsonResponse(request, 200, %*{"ok": true, "token": name.get})

const
  ## The per-code ceiling is the per-viewer one times this factor: everyone
  ## watching the same link shares one budget instead of competing for it.
  shareGlobalFactor = 10

const requiredRelations = [
  # One name per area the process cannot work without. The lookup reads
  # pg_class rather than to_regclass(): the latter needs USAGE on the schema it
  # is asked about, and dbtools is the owner's ledger, so a regular app role
  # would turn a healthy database into a false "unreachable" on /readyz.
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
         where not exists (
           select 1
             from pg_class c
             join pg_namespace n on n.oid = c.relnamespace
            where n.nspname = split_part(wanted.name, '.', 1)
              and c.relname = split_part(wanted.name, '.', 2))""",
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
    # The reason is for the operator's log, never the anonymous caller. A probe
    # only needs "not ready"; naming the missing relation, the unreachable
    # database or a wrong snapshot tells a scanner which half of the system is
    # fragile, and distinguishing a wrong dump from a migration gap is exactly
    # the reconnaissance this route should not offer.
    logError("readiness refused",
      [("detail", detail), ("request_id", currentRequestId())])
    send(request, 503, """{"status":"not_ready"}""")

proc sessionVersionNow(communityId, sessionId: string): int =
  sessionDetail.versionOf(database(), communityId, sessionId)

proc sessionApproved(communityId, sessionId: string): bool =
  ## The same two-column test the rating ledger uses: an approval stamp with a
  ## status outside the approved set would otherwise let a draft be rated.
  sessionDetail.isApproved(database(), communityId, sessionId)

proc ingestSessionRating(request: Request, ctx: CommunityContext,
                         user: AuthUser, sessionId: string,
                         snapshot: Snapshot) =
  ## A session id that names nothing in this community is a 404, not a silent
  ## ingest of zero rows that the caller cannot tell apart from a no-op.
  if sessionVersionNow(ctx.communityId, sessionId) == 0:
    problem(request, 404, "NOT_FOUND", "session not found")
    return
  if not sessionApproved(ctx.communityId, sessionId):
    problem(request, 409, "CONFLICT", "session is not approved")
    return
  let params = ratingParamsFor(ctx, snapshot)
  var result: ratingIngest.IngestResult
  auditedWrite(proc(tx: Db, conn: DbConn) =
    result = ratingIngest.ingestSession(tx, ctx.communityId,
      sessionId, params)
    auditConn(conn, "rating.session.ingest", ctx, user, "session", sessionId,
      %*{"events": result.events, "deltas": result.deltas}))
  discard application.ratingJobs.enqueue(ratingJobs.jkReconcile,
    ctx.communityId)
  jsonResponse(request, 200, %*{"events": result.events,
    "deltas": result.deltas})

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
  var removed = 0
  auditedWrite(proc(tx: Db, conn: DbConn) =
    removed = ratingIngest.revertSource(tx, ctx.communityId, sessionId)
    auditConn(conn, "rating.session.revert", ctx, user, "session", sessionId,
      %*{"removedDeltas": removed}))
  if removed > 0:
    discard application.ratingJobs.enqueue(ratingJobs.jkRebuild,
      ctx.communityId)
  # The row is gone; the ledger replay that derives the board is queued. Only
  # the count this request actually removed is reported, because a zero for
  # `events`/`deltas` described work the response never did.
  jsonResponse(request, 200, %*{"removedDeltas": removed})

proc rebuildRatings(request: Request, ctx: CommunityContext,
                    user: AuthUser) =
  ## Accepted, not completed: the worker replays the ledger after the response.
  ## The old handler held a pool connection and the community lock for the whole
  ## replay, which is what turned one click into a process-wide stall.
  let job = application.ratingJobs.enqueue(ratingJobs.jkRebuild,
    ctx.communityId)
  if job.len == 0:
    problem(request, 503, "UNAVAILABLE", "rating worker is busy")
    return
  auditedWrite(proc(tx: Db, conn: DbConn) =
    auditConn(conn, "rating.rebuild", ctx, user, "community", ctx.communityId,
      %*{"job": job}))
  # Stable acknowledgement only: the job id is a per-process counter and is
  # not part of the contract, so a client cannot depend on it.
  jsonResponse(request, 202, %*{"status": "accepted"})

proc listRatingSources(request: Request, ctx: CommunityContext,
                       snapshot: Snapshot) =
  ## Events and the tournaments that were never ingested are one list: the
  ## admin has to sign both off. The union keeps the order, the page window and
  ## the total in the database, so neither half is unbounded on its own.
  let (limit, offset) = pageParams(request, snapshot)
  let sourcesSql = """
    select id, event_type, local_date, source_id, deltas, finalized,
           finalized_at
    from (
      select e.id, e.event_type, e.local_date::text as local_date,
             coalesce(e.source_id::text, '') as source_id,
             e.point_entries::int as deltas,
             coalesce(s.finalized, false) as finalized,
             s.finalized_at::text as finalized_at,
             e.created_at as sort_at
      from rating.events e
      left join rating.sources s
        on s.community_id = e.community_id and s.source_id = e.source_id
      where e.community_id = $1::uuid
      union all
      select t.id, 'tournament' as event_type, t.event_date::text,
             t.id::text as source_id, 0 as deltas,
             coalesce(s.finalized, false) as finalized,
             s.finalized_at::text as finalized_at,
             t.created_at as sort_at
      from tournament.tournaments t
      left join rating.sources s
        on s.community_id = t.community_id and s.source_id = t.id
      where t.community_id = $1::uuid
        and not exists (
          select 1 from rating.events e
          where e.community_id = t.community_id
            and e.event_type = 'tournament' and e.source_id = t.id)
    ) sources
  """
  var items = newJArray()
  for row in application.db.query(
    sourcesSql & """ order by local_date desc, sort_at desc
                     limit $2 offset $3""",
    @[textParam(ctx.communityId), intParam(limit.int64),
      intParam(offset.int64)]):
    items.add(%*{"id": row.get("id"), "type": row.get("event_type"),
      "date": row.get("local_date"), "sourceId": row.get("source_id"),
      "deltas": parseInt(row.get("deltas")),
      "finalized": row.get("finalized") == "t",
      "finalizedAt": if row["finalized_at"].isSome:
        %row.get("finalized_at") else: newJNull()})
  let totalRow = application.db.queryOne(
    "select count(*)::int as total from (" & sourcesSql & ") sources",
    @[textParam(ctx.communityId)])
  let total = if totalRow.isSome: parseInt(totalRow.get.get("total")) else: 0
  pagedJson(request, items, total, limit, offset)

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
  # The delete and its evidence share one transaction. The replay runs on the
  # worker afterwards, so a failed replay cannot roll back a delete the caller
  # was told had happened.
  var removed = 0
  application.db.tx(proc(conn: DbConn) =
    removed = ratingIngest.removeEventConn(conn, ctx.communityId, eventId)
    auditConn(conn, "rating.source.delete", ctx, user, "rating_event", eventId,
      %*{"removedDeltas": removed}))
  if removed > 0:
    discard application.ratingJobs.enqueue(ratingJobs.jkRebuild,
      ctx.communityId)
  jsonResponse(request, 200, %*{"removedDeltas": removed})

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
  # Delete and revert in one transaction. The ledger replay that follows is a
  # worker job, because holding this transaction open for it is what made a
  # delete as expensive as the community's whole history.
  var outcome = sessionWrite.dsDeleted
  var removed = 0
  application.db.tx(proc(conn: DbConn) =
    outcome = sessionWrite.removeConn(conn, ctx.communityId, sessionId,
      ctx.role == rAdmin)
    if outcome == sessionWrite.dsDeleted:
      removed = ratingIngest.revertSourceConn(conn, ctx.communityId, sessionId)
      discard ratingIngest.dropSourceConn(conn, ctx.communityId, sessionId)
      auditConn(conn, "session.delete", ctx, user, "session", sessionId,
        %*{"removedDeltas": removed}))
  case outcome
  of sessionWrite.dsNotFound:
    problem(request, 404, "NOT_FOUND", "session not found")
    return
  of sessionWrite.dsNotDraft:
    problem(request, 403, "FORBIDDEN", "only an admin can delete this session")
    return
  of sessionWrite.dsDeleted:
    if removed > 0:
      discard application.ratingJobs.enqueue(ratingJobs.jkRebuild,
        ctx.communityId)
  for linkId in links:
    application.hub.revokeShare(linkId)
  send(request, 204)

proc patchRatingSource(request: Request, ctx: CommunityContext, user: AuthUser,
                       eventId: string,
                    snapshot: Snapshot) =
  var body: JsonNode
  if not jsonBody(request, snapshot, body):
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
  var updated: Option[JsonNode]
  auditedWrite(proc(tx: Db, conn: DbConn) =
    updated = ratingIngest.setFinalized(tx, ctx.communityId,
      eventId, finalized)
    if updated.isSome:
      auditConn(conn, "rating.source.finalize", ctx, user, "rating_event",
        eventId, %*{"finalized": finalized}))
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
      # source instead of leaving the ledger on a stale result. The replay is
      # queued; this route only records the decision.
      discard application.ratingJobs.enqueue(ratingJobs.jkRebuild,
        ctx.communityId)
  jsonResponse(request, 200, updated.get)

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
  of sessionSchedule.ssInvalidSequence:
    problem(request, 400, "INVALID_SET_SEQUENCE",
      "sets must stop once the match is won")
  of sessionSchedule.ssHasSets:
    problem(request, 409, "MATCH_HAS_SETS",
      "clear the recorded sets before marking the match played")
  of sessionSchedule.ssLocked:
    problem(request, 403, "FORBIDDEN", "session is locked")
  of sessionSchedule.ssUnknownPlayer:
    problem(request, 400, "UNKNOWN_PLAYER", "player is not in this community")
  of sessionSchedule.ssNotParticipant:
    problem(request, 400, "NOT_PARTICIPANT", "player is not in this session")

proc scheduleAudit(ctx: CommunityContext, user: AuthUser, action,
                  sessionId: string, evidence: JsonNode) =
  ## One row per mutating scoring call. The schedule store owns its own
  ## transaction, so this row commits after the write instead of with it; a
  ## failed insert is logged rather than turning a saved score into a 500.
  try:
    recordAudit(application.db, evidenceEvent(action, ctx.communityId, user,
      "session", sessionId, evidence, $ctx.role))
  except DbError as error:
    logError("scoring write not audited",
      [("error", error.msg), ("action", action)])

proc scheduleDone(request: Request, ctx: CommunityContext, user: AuthUser,
                  action: string, evidence: JsonNode, sessionId: string,
                  status: sessionSchedule.ScheduleStatus) =
  if status != sessionSchedule.ssOk:
    scheduleProblem(request, status)
    return
  # The writes that decide ranking points are the ones with no attributable
  # record otherwise: a host could change a score before approval and the only
  # trace would be the final value plus a version counter.
  scheduleAudit(ctx, user, action, sessionId, evidence)
  let version = sessionVersionNow(ctx.communityId, sessionId)
  application.hub.sessionChanged(sessionId, version)
  jsonResponse(request, 200, %*{"version": version},
    [("ETag", "\"" & $version & "\"")])

proc putScheduleRoute(request: Request, ctx: CommunityContext, user: AuthUser,
                    sessionId: string, snapshot: Snapshot) =
  let version = requireIfMatch(request)
  if version.isNone: return
  var games: seq[sessionSchedule.GameSpec]
  try:
    games = sessionSchedule.parseSchedule(bodyJson(request, snapshot))
  except ValueError as error:
    logWarn("schedule rejected",
      [("error", error.msg), ("path", request.path)])
    problem(request, 400, "INVALID_SCHEDULE", error.msg)
    return
  scheduleDone(request, ctx, user, "session.schedule.put",
    %*{"count": games.len}, sessionId,
    sessionSchedule.putSchedule(application.db, ctx.communityId, sessionId,
      version.get, games))

proc setAbsentRoute(request: Request, ctx: CommunityContext, user: AuthUser,
                    sessionId: string, snapshot: Snapshot) =
  let version = requireIfMatch(request)
  if version.isNone: return
  var playerIds: seq[string]
  try:
    playerIds = sessionSchedule.parsePlayerIds(bodyJson(request, snapshot))
  except ValueError as error:
    logWarn("absent list rejected",
      [("error", error.msg), ("path", request.path)])
    problem(request, 400, "INVALID_SCHEDULE", error.msg)
    return
  scheduleDone(request, ctx, user, "session.absent.set", %*{"count": playerIds.len},
    sessionId,
    sessionSchedule.setAbsent(application.db, ctx.communityId, sessionId,
      version.get, playerIds))

proc setVerdictProblem(request: Request, verdict: sessionScoring.SetVerdict) =
  ## The one table from a verdict to its HTTP code and message. `setSets` already
  ## validated the list inside its transaction and handed the verdict back, so
  ## the route never runs the rules a second time.
  let prefix =
    if verdict.setIndex > 0: "set " & $verdict.setIndex & ": " else: ""
  case verdict.error
  of sessionScoring.seOk:
    discard
  of sessionScoring.seTie:
    problem(request, 400, "INVALID_SCORE", prefix & "scores cannot be equal")
  of sessionScoring.seRange:
    problem(request, 400, "INVALID_SCORE",
      prefix & "scores must be between 0 and 99")
  of sessionScoring.seTooFewPoints:
    problem(request, 400, "INVALID_SCORE",
      prefix & "the winner must reach the format's points")
  of sessionScoring.seAboveCap:
    problem(request, 400, "INVALID_SCORE",
      prefix & "the score is above the format's cap")
  of sessionScoring.seWinBy:
    problem(request, 400, "INVALID_SCORE",
      prefix & "the winning margin is too small")
  of sessionScoring.seTooManySets:
    problem(request, 400, "INVALID_SET_SEQUENCE",
      "too many sets for this format")
  of sessionScoring.seSetAfterEnd:
    problem(request, 400, "INVALID_SET_SEQUENCE",
      prefix & "the match is already won")
  of sessionScoring.seSetsRequired:
    problem(request, 400, "SETS_REQUIRED",
      "this format needs set scores, not a single score")

proc setGameScoreRoute(request: Request, ctx: CommunityContext, user: AuthUser,
                       sessionId, gameKey: string,
                    snapshot: Snapshot) =
  let version = requireIfMatch(request)
  if version.isNone: return
  var body: JsonNode
  if not jsonBody(request, snapshot, body):
    return
  if body.kind != JObject:
    problem(request, 400, "INVALID_BODY", "body must be an object")
    return
  if body.hasKey("played"):
    if body["played"].kind != JBool:
      problem(request, 400, "INVALID_BODY", "played must be a boolean")
      return
    scheduleDone(request, ctx, user, "session.game.played",
      %*{"gameKey": gameKey,
         "status": (if body["played"].getBool(): "played" else: "scheduled")},
      sessionId,
      sessionSchedule.setPlayed(application.db, ctx.communityId, sessionId,
        gameKey, version.get, body["played"].getBool()))
    return
  var sets: seq[sessionScoring.SetScore]
  let hasSets = body.hasKey("sets")
  if hasSets:
    try:
      sets = sessionScoring.parseSets(body["sets"])
    except ValueError as error:
      logWarn("score rejected",
        [("error", error.msg), ("path", request.path)])
      problem(request, 400, "INVALID_SCORE", error.msg)
      return
  else:
    if not body.hasKey("scoreA") or not body.hasKey("scoreB") or
       body["scoreA"].kind != JInt or body["scoreB"].kind != JInt:
      problem(request, 400, "INVALID_SCORE",
        "sets or scoreA and scoreB are required")
      return
    sets = @[sessionScoring.SetScore(a: body["scoreA"].getInt(),
                                     b: body["scoreB"].getInt())]

  let outcome = sessionSchedule.setSets(application.db, ctx.communityId,
    sessionId, gameKey, version.get, sets, flat = not hasSets)
  if outcome.verdict.error != sessionScoring.seOk:
    setVerdictProblem(request, outcome.verdict)
    return
  scheduleDone(request, ctx, user, "session.game.score",
    %*{"gameKey": gameKey, "count": sets.len}, sessionId, outcome.status)

proc skipGameRoute(request: Request, ctx: CommunityContext, user: AuthUser,
                   sessionId, gameKey: string,
                    snapshot: Snapshot) =
  let version = requireIfMatch(request)
  if version.isNone: return
  var body: JsonNode
  if not jsonBody(request, snapshot, body):
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
    scheduleDone(request, ctx, user, "session.game.skip",
      %*{"gameKey": gameKey, "count": playerIds.len}, sessionId,
      sessionSchedule.setSkips(application.db, ctx.communityId, sessionId,
        gameKey, version.get, playerIds))
    return
  scheduleDone(request, ctx, user, "session.game.skip", %*{"gameKey": gameKey},
    sessionId,
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
  jsonResponse(request, 200, board.get)

proc scoringJson(rules: sessionScoring.ScoringRules): JsonNode =
  ## The public view of a session's frozen format. `mode` and the internal
  ## target stay out; the client only needs what it renders and validates.
  result = %*{
    "preset": rules.id,
    "label": rules.label,
    "gamesToWin": rules.gamesToWin,
    "pointsToWin": rules.pointsToWin,
    "winBy": rules.winBy,
    "maxPoints": rules.maxPoints,
  }
  result["deuceAt"] =
    if rules.deuceAt.isSome: %rules.deuceAt.get else: newJNull()
  result["changeEndsAt"] =
    if rules.changeEndsAt.isSome: %rules.changeEndsAt.get else: newJNull()

proc gameSets(entries: seq[sessionDetail.GameSet]): JsonNode =
  result = newJArray()
  for entry in entries:
    result.add(%*{"set": entry.setNo, "a": entry.a, "b": entry.b})

proc gameJson(game: sessionDetail.Game): JsonNode =
  ## One match from the results view. `scoreA/scoreB` are total points, kept
  ## under the old names so existing readers do not break; the winner comes from
  ## sets, never from comparing totals.
  var sideA = newJArray()
  var sideB = newJArray()
  let split = sessionSides.sides(game.sideA1, game.sideA2, game.sideB1,
    game.sideB2, initHashSet[string](), initHashSet[string]())
  for playerId in split.presentA:
    sideA.add(%playerId)
  for playerId in split.presentB:
    sideB.add(%playerId)
  # A match with no set has no score. Keeping NULL here matters: the legacy
  # adapter treats a non-null 0-0 as a recorded result.
  let scored = game.setsPlayed > 0
  %*{
    "round": game.roundNo,
    "court": game.courtNo,
    "sideA": sideA,
    "sideB": sideB,
    "scoreA": if scored: %game.pointsA else: newJNull(),
    "scoreB": if scored: %game.pointsB else: newJNull(),
    "setsWonA": game.setsA,
    "setsWonB": game.setsB,
    "winner": if game.winner == "a": %"A" elif game.winner == "b": %"B" else: newJNull(),
    "sets": gameSets(game.sets),
    "status": game.status,
  }

proc getSessionDetail(request: Request, ctx: CommunityContext,
                      sessionId: string) =
  ## The whole session in one read: header, who is playing and the games. The
  ## schedule has a write endpoint but no read of its own, and a page cannot
  ## render games it has no keys for.
  let loaded = sessionDetail.load(database(), ctx.communityId, sessionId)
  if loaded.isNone:
    problem(request, 404, "NOT_FOUND", "session not found")
    return
  let session = loaded.get
  let etag = "\"" & $session.version & "\""
  # A poll that already has this version costs a 304 instead of the full read.
  if ifNoneMatchHits(request, etag):
    send(request, 304, @[("ETag", etag), ("Cache-Control", "no-store")], "")
    return
  var participants = newJArray()
  for entry in session.participants:
    participants.add(%*{"playerId": entry.playerId, "name": entry.name,
      "absent": entry.absent})
  var games = newJArray()
  for game in session.games:
    games.add(gameJson(game))
  var skipped = newJObject()
  for entry in session.skips:
    let key = $entry.roundNo & "-" & $entry.courtNo
    if not skipped.hasKey(key):
      skipped[key] = newJArray()
    skipped[key].add(%entry.playerId)
  jsonResponse(request, 200, %*{
    "id": session.id,
    "title": session.title,
    "date": session.date,
    "startTime": session.startTime,
    "slotMinutes": session.slotMinutes,
    "status": session.status,
    "version": session.version,
    "scoring": scoringJson(session.rules),
    "participants": participants,
    "games": games,
    "skippedPlayers": skipped},
    [("ETag", etag)])

proc getGameRoute(request: Request, ctx: CommunityContext, sessionId,
                  gameKey: string) =
  let key = sessionSchedule.parseGameKey(gameKey)
  if key.isNone:
    problem(request, 400, "INVALID_GAME_KEY", "gameKey must be round-court")
    return
  let found = sessionDetail.loadGame(database(), ctx.communityId, sessionId,
    key.get[0], key.get[1])
  if found.isNone:
    problem(request, 404, "NOT_FOUND", "game not found")
    return
  jsonResponse(request, 200, gameJson(found.get))

proc getShareLink(request: Request, ctx: CommunityContext, user: AuthUser,
                  sessionId: string) =
  ## Re-display of the live code: host/admin only, and every read is audited.
  let code = shareStore.currentCode(application.db, application.keyring,
    ctx.communityId, sessionId)
  if code.isNone:
    problem(request, 404, "NOT_FOUND", "no live share link")
    return
  auditedWrite(proc(tx: Db, conn: DbConn) =
    auditConn(conn, "share.redisplay", ctx, user, "session", sessionId,
      %*{"sessionId": sessionId}))
  jsonResponse(request, 200, %*{"code": code.get, "sessionId": sessionId})

proc publicStandings(board: Option[JsonNode]): JsonNode =
  ## The public screen and the member page read the same board, so the share
  ## payload mirrors the member route item for item. It carries names, never
  ## ids: a spectator has no session to resolve a uuid against.
  if board.isNone:
    return newJNull()
  var items = newJArray()
  for entry in board.get["items"]:
    items.add(%*{
      "name": entry["name"],
      "wins": entry["wins"],
      "losses": entry["losses"],
      "pointsFor": entry["pointsFor"],
      "pointsAgainst": entry["pointsAgainst"],
      "diff": entry["diff"],
    })
  %*{"items": items}

proc resolveShare(code: string): Option[JsonNode] =
  let found = shareStore.resolve(application.db, application.keyring, code)
  if found.isNone:
    return none(JsonNode)
  let value = found.get
  let rules = sessionSchedule.sessionRules(application.db, value.communityId,
    value.sessionId)
  # Every set of the session in one statement: the public payload is polled by
  # a whole group chat and must not cost one query per game.
  let allSets = sessionDetail.setsByGame(application.db, value.communityId,
    value.sessionId)
  var games = newJArray()
  for row in application.db.query(
    """select r.round_no, r.court_no, r.status, r.winner,
              r.points_a, r.points_b, r.sets_played, r.sets_a, r.sets_b,
              coalesce(a1.canonical_name, '') as a1,
              coalesce(a2.canonical_name, '') as a2,
              coalesce(b1.canonical_name, '') as b1,
              coalesce(b2.canonical_name, '') as b2
       from session.game_results r
       left join player.players a1 on a1.id = r.side_a1
       left join player.players a2 on a2.id = r.side_a2
       left join player.players b1 on b1.id = r.side_b1
       left join player.players b2 on b2.id = r.side_b2
       where r.community_id = $1::uuid and r.session_id = $2::uuid
       order by r.round_no, r.court_no""",
    @[textParam(value.communityId), textParam(value.sessionId)]):
    # Names, not ids: a spectator cannot resolve a uuid, and the share payload
    # is the only read that has no session behind it. The round and the court
    # are the keys the public screen renders by, so nothing needs the id.
    var sideA = newJArray()
    var sideB = newJArray()
    for slot in ["a1", "a2"]:
      if row.get(slot).len > 0: sideA.add(%row.get(slot))
    for slot in ["b1", "b2"]:
      if row.get(slot).len > 0: sideB.add(%row.get(slot))
    let winner = row.get("winner")
    let scored = parseInt(row.get("sets_played")) > 0
    games.add(%*{
      "round": parseInt(row.get("round_no")),
      "court": parseInt(row.get("court_no")),
      "sideA": sideA, "sideB": sideB,
      "scoreA": if scored: %parseInt(row.get("points_a")) else: newJNull(),
      "scoreB": if scored: %parseInt(row.get("points_b")) else: newJNull(),
      "setsWonA": parseInt(row.get("sets_a")),
      "setsWonB": parseInt(row.get("sets_b")),
      "winner": if winner == "a": %"A" elif winner == "b": %"B" else: newJNull(),
      "sets": gameSets(allSets.sets(parseInt(row.get("round_no")),
        parseInt(row.get("court_no")))),
      "status": row.get("status"),
    })
  var shared = %*{
    # No session id: the code is the only public key of this read, and the
    # legacy `/s/<id>` alias would make the published uuid a second one.
    "session": {"title": value.title,
                "date": value.sessionDate, "status": value.status},
    "community": {"slug": value.slug, "name": value.communityName},
    "games": games,
    "standings": publicStandings(sessionStandings.compute(application.db,
      value.communityId, value.sessionId)),
  }
  if rules.isSome:
    shared["scoring"] = scoringJson(rules.get)
  some(shared)

proc getShared(request: Request, code: string) =
  let shared = resolveShare(code)
  if shared.isNone:
    problem(request, 404, "NOT_FOUND", "link not found")
    return
  jsonResponse(request, 200, shared.get,
    [("X-Robots-Tag", "noindex")])

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
                    snapshot: Snapshot, settings: JsonNode,
                    playerIds: seq[string] = @[]) =
  ## The member page reads the whole community board; a share link passes the
  ## session's participants so the public copy is one session, not the ladder.
  let params = ratingParams.loadRatingParams(snapshot, settings)
  let limit = snapshot.intValue(settings, keyRankBoardLimit)
  let minSessions = minSessionsParam(request,
    snapshot.intValue(settings, keyRankMinSessions))
  let latest = ratingRead.latestEventDate(application.db, communityId)
  let asOf =
    if latest.len > 0: latest else: communityToday(application.db, timezone)
  let query = ratingRead.BoardQuery(communityId: communityId,
    asOf: asOf, params: params, limit: limit,
    tier: tierParam(request), minSessions: minSessions,
    playerIds: playerIds)
  let rows = ratingRead.board(application.db, query)
  jsonResponse(request, 200, %*{"items": boardItems(rows),
    "asOf": asOf,
    "windowWeeks": params.windowWeeks, "bestN": params.bestN,
    "minSessions": minSessions})

proc rankingPlayer(request: Request, communityId, timezone, playerId: string,
                   snapshot: Snapshot, settings: JsonNode,
                   playerIds: seq[string] = @[]) =
  let params = ratingParams.loadRatingParams(snapshot, settings)
  let limit = snapshot.intValue(settings, keyRankBoardLimit)
  let latest = ratingRead.latestEventDate(application.db, communityId)
  let asOf =
    if latest.len > 0: latest else: communityToday(application.db, timezone)
  # `min_sessions` means the same filter as on the board: a player below it is
  # not on the ranking either, instead of the detail route ignoring it.
  let minSessions = minSessionsParam(request,
    snapshot.intValue(settings, keyRankMinSessions))
  let query = ratingRead.BoardQuery(communityId: communityId,
    asOf: asOf, params: params, limit: limit, tier: "",
    minSessions: minSessions, playerIds: playerIds)
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
  item["minSessions"] = %minSessions
  item["thinEvidenceN"] = %params.thinEvidenceN
  jsonResponse(request, 200, item)

proc playerAchievements(request: Request, ctx: CommunityContext,
                        playerId: string, snapshot: Snapshot) =
  if playerStore.get(application.db, ctx.communityId, playerId).isNone:
    problem(request, 404, "NOT_FOUND", "player not found")
    return
  let (limit, offset) = pageParams(request, snapshot)
  let items = achievementBackfill.listForPlayer(application.db,
    ctx.communityId, playerId, limit, offset)
  var body = newJArray()
  for item in items:
    body.add(item)
  pagedJson(request, body,
    achievementBackfill.countForPlayer(application.db, ctx.communityId,
      playerId), limit, offset)

proc boardPoints(communityId, timezone, playerId: string,
                 snapshot: Snapshot, settings: JsonNode): int =
  ## The one points number the API exposes: the player's row on today's board,
  ## resolved the same way the leaderboard resolves it. A player with no entry
  ## in the window has no row, so the page shows zero instead of a career total
  ## no board ever displayed.
  let params = ratingParams.loadRatingParams(snapshot, settings)
  let limit = snapshot.intValue(settings, keyRankBoardLimit)
  let latest = ratingRead.latestEventDate(application.db, communityId)
  let asOf =
    if latest.len > 0: latest else: communityToday(application.db, timezone)
  let row = ratingRead.boardEntry(application.db, ratingRead.BoardQuery(
    communityId: communityId, asOf: asOf, params: params, limit: limit,
    tier: ""), playerId)
  if row.isSome: row.get.points else: 0

proc playerStats(request: Request, ctx: CommunityContext, playerId: string,
                 snapshot: Snapshot) =
  let found = ratingRead.stats(application.db, ctx.communityId, playerId)
  if found.isNone:
    problem(request, 404, "NOT_FOUND", "player not found")
    return
  var body = found.get
  body["points"] = %boardPoints(ctx.communityId, ctx.timezone, playerId,
    snapshot, ctx.settings)
  jsonResponse(request, 200, body)

proc sessionPlayerIds(communityId, sessionId: string): seq[string] =
  ## The players who took part in one session. A share code opens that session,
  ## so the public board it serves is this set and never the whole community.
  sessionDetail.participantIds(database(), communityId, sessionId)

proc getSharedRanking(request: Request, code, playerId: string,
                      snapshot: Snapshot) =
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
  let settings = currentSettings(application.db, found.get.communityId)
  rankingPlayer(request, found.get.communityId, found.get.timezone, playerId,
    snapshot, settings, playerIds)

proc getSharedRankings(request: Request, code: string, snapshot: Snapshot) =
  let found = shareStore.resolve(application.db, application.keyring, code)
  if found.isNone:
    problem(request, 404, "NOT_FOUND", "link not found")
    return
  let settings = currentSettings(application.db, found.get.communityId)
  communityBoard(request, found.get.communityId, found.get.timezone, snapshot,
    settings, sessionPlayerIds(found.get.communityId, found.get.sessionId))

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
    originNotAllowed(request)
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
  routeNotFound(request)

proc sendSnapshot(request: Request, status: int, snapshot: JsonNode,
                  extra: openArray[(string, string)] = []) =
  let etag =
    if snapshot.hasKey("version"):
      "\"" & $snapshot["version"].getInt() & "\""
    else:
      ""
  # The same conditional read the session detail already offers, so a poll that
  # holds the current version costs a 304 instead of the whole bracket. Only a
  # GET may answer 304: a write that carries If-None-Match has already
  # committed and must return its body.
  if request.httpMethod == "GET" and status == 200 and etag.len > 0 and
      ifNoneMatchHits(request, etag):
    send(request, 304, @[("ETag", etag), ("Cache-Control", "no-store")], "")
    return
  var headers: seq[(string, string)] = @[]
  if etag.len > 0:
    headers.add(("ETag", etag))
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

proc listTournamentsRoute(request: Request, ctx: CommunityContext,
                          snapshot: Snapshot) =
  let (limit, offset) = pageParams(request, snapshot)
  var items = newJArray()
  for item in tournamentStore.list(application.db, ctx.communityId,
      request.queryParams.getOrDefault("format", ""), limit, offset):
    items.add(item)
  jsonResponse(request, 200, %*{"items": items})

proc createTournamentRoute(request: Request, ctx: CommunityContext,
                           user: AuthUser,
                    snapshot: Snapshot) =
  # Parse before claiming: a malformed body must not own the key, or the
  # corrected retry answers 409 for the rest of the TTL.
  var body: JsonNode
  if not jsonBody(request, snapshot, body):
    return
  let claimed = claimWrite(request, ctx, user)
  if claimed.isNone:
    return
  let w = claimed.get
  var status: tournamentStore.SaveStatus
  var snapshot: JsonNode
  auditedWrite(proc(tx: Db, conn: DbConn) =
    (status, snapshot) = tournamentStore.create(tx,
      ctx.communityId, user.id, body)
    if status == tournamentStore.svOk:
      let id = snapshot["id"].getStr()
      auditConn(conn, "tournament.create", ctx, user, "tournament", id,
        %*{"id": id, "version": snapshot["version"]}))
  if status == tournamentStore.svInvalid:
    w.release()
    invalidBodyResponse(request, "INVALID_TOURNAMENT",
      "tournament body is invalid", snapshot)
    return
  if status != tournamentStore.svOk:
    w.release()
    saveFailure(request, status)
    return
  let id = snapshot["id"].getStr()
  w.complete(201, snapshot)
  sendSnapshot(request, 201, snapshot,
    [("Location", "/c/" & ctx.slug & "/tournaments/" & id)])

proc getTournamentRoute(request: Request, ctx: CommunityContext, id: string) =
  let snapshot = tournamentStore.load(application.db, ctx.communityId, id)
  if snapshot.isNone:
    problem(request, 404, "NOT_FOUND", "tournament not found")
    return
  sendSnapshot(request, 200, snapshot.get)

proc putTournamentRoute(request: Request, ctx: CommunityContext, user: AuthUser,
                        id: string,
                    snapshot: Snapshot) =
  let version = requireIfMatch(request)
  if version.isNone:
    return
  # The body is parsed before the key is claimed, so a 400 leaves no owner.
  var body: JsonNode
  if not jsonBody(request, snapshot, body):
    return
  let claimed = claimWrite(request, ctx, user, "tournament/" & id)
  if claimed.isNone:
    return
  let w = claimed.get
  var status: tournamentStore.SaveStatus
  var snapshot: JsonNode
  auditedWrite(proc(tx: Db, conn: DbConn) =
    (status, snapshot) = tournamentStore.replace(tx,
      ctx.communityId, id, user.id, body, version.get)
    if status == tournamentStore.svOk:
      auditConn(conn, "tournament.update", ctx, user, "tournament", id,
        %*{"id": id, "version": snapshot["version"]}))
  case status
  of tournamentStore.svOk:
    w.complete(200, snapshot)
    sendSnapshot(request, 200, snapshot)
  of tournamentStore.svInvalid:
    w.release()
    invalidBodyResponse(request, "INVALID_TOURNAMENT",
      "tournament body is invalid", snapshot)
  else:
    w.release()
    saveFailure(request, status)

proc ingestTournamentRating(request: Request, ctx: CommunityContext,
                           user: AuthUser, id: string, snapshot: Snapshot) =
  ## Admin-only. The source must be signed off first, which is the v1 gate and
  ## the reason a running bracket cannot leak half a tournament into the board.
  let params = ratingParamsFor(ctx, snapshot)
  var result: ratingTournament.TournamentIngestResult
  auditedWrite(proc(tx: Db, conn: DbConn) =
    result = ratingTournament.ingestTournament(tx,
      ctx.communityId, id, params)
    if result.status == ratingTournament.tisOk:
      auditConn(conn, "rating.tournament.ingest", ctx, user, "tournament", id,
        %*{"events": result.events, "deltas": result.deltas}))
  case result.status
  of ratingTournament.tisOk:
    discard application.ratingJobs.enqueue(ratingJobs.jkReconcile,
      ctx.communityId)
    jsonResponse(request, 200, %*{"events": result.events,
      "deltas": result.deltas})
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
  var removed = 0
  auditedWrite(proc(tx: Db, conn: DbConn) =
    removed = ratingIngest.revertSource(tx, ctx.communityId, id)
    auditConn(conn, "rating.tournament.revert", ctx, user, "tournament", id,
      %*{"removedDeltas": removed}))
  if removed > 0:
    discard application.ratingJobs.enqueue(ratingJobs.jkRebuild,
      ctx.communityId)
  send(request, 204)

proc deleteTournamentRoute(request: Request, ctx: CommunityContext,
                           user: AuthUser, id: string) =
  ## The Idempotency-Key is accepted but not persisted: a repeated delete is
  ## already a 404, and a 204 must not carry a replay body. A signed-off source
  ## has to be reverted first: deleting it would erase a ledger decision.
  if ratingIngest.sourceFinalized(application.db, ctx.communityId, id):
    problem(request, 403, "FORBIDDEN", "rating source is finalized")
    return
  var deleted = false
  var removed = 0
  auditedWrite(proc(tx: Db, conn: DbConn) =
    deleted = tournamentStore.remove(tx, ctx.communityId, id)
    if deleted:
      # The rating event named this tournament; deleting the tournament without
      # it would leave points on the board for a bracket that no longer exists.
      removed = ratingIngest.revertSource(tx, ctx.communityId, id)
      discard ratingIngest.dropSource(tx, ctx.communityId, id)
      auditConn(conn, "tournament.delete", ctx, user, "tournament", id,
        %*{"id": id, "removedDeltas": removed}))
  if not deleted:
    problem(request, 404, "NOT_FOUND", "tournament not found")
    return
  if removed > 0:
    discard application.ratingJobs.enqueue(ratingJobs.jkRebuild,
      ctx.communityId)
  send(request, 204)

proc patchTournamentMatchRoute(request: Request, ctx: CommunityContext,
                               user: AuthUser, id, matchId: string,
                    snapshot: Snapshot) =
  let version = requireIfMatch(request)
  if version.isNone:
    return
  # Same order as the other two: parse, then claim.
  var body: JsonNode
  if not jsonBody(request, snapshot, body):
    return
  let claimed = claimWrite(request, ctx, user,
    "tournament/" & id & "/match/" & matchId)
  if claimed.isNone:
    return
  let w = claimed.get
  var status: tournamentStore.PatchStatus
  var snapshot: JsonNode
  auditedWrite(proc(tx: Db, conn: DbConn) =
    (status, snapshot) = tournamentStore.patchMatch(tx,
      ctx.communityId, id, matchId, body, version.get)
    if status == tournamentStore.ptOk:
      auditConn(conn, "tournament.match.patch", ctx, user, "tournament", id,
        %*{"id": id, "matchId": matchId, "version": snapshot["version"]}))
  case status
  of tournamentStore.ptOk:
    w.complete(200, snapshot)
    sendSnapshot(request, 200, snapshot)
  of tournamentStore.ptInvalid:
    w.release()
    invalidBodyResponse(request, "INVALID_TOURNAMENT",
      "tournament match body is invalid", snapshot)
  of tournamentStore.ptNotFound:
    w.release()
    problem(request, 404, "NOT_FOUND", "tournament or match not found")
  of tournamentStore.ptStale:
    w.release()
    problem(request, 412, "STALE_VERSION", "tournament changed since If-Match")
  of tournamentStore.ptLocked:
    w.release()
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

proc rejectLargeBody(request: Request, snapshot: Snapshot): bool =
  ## `true` means the 413 is already sent, so `route()` is one chain of guards
  ## that answer for themselves.
  if request.body.len == 0 or not bodyTooLarge(request, snapshot):
    return false
  problem(request, 413, "BODY_TOO_LARGE", "request body exceeds the limit")
  true

proc rejectCrossSite(request: Request, snapshot: Snapshot): bool =
  if csrfCheck(request, snapshot) != csrfRejected:
    return false
  originNotAllowed(request)
  true

proc rejectShareScrape(request: Request, snapshot: Snapshot,
                       identity: RateIdentity): bool =
  ## Share links are limited per viewer, so one scraper cannot exhaust the
  ## budget of the group that holds the link, and per code at a looser ceiling
  ## so a pool of addresses still cannot replay a scraped code without bound.
  ## The identity was resolved once for the route quota, so this check never
  ## validates the cookie a second time.
  let path = request.path
  if not path.startsWith("/s/"):
    return false
  let parts = path.split('/')
  if parts.len < 3:
    return false
  let codeKey = sha256Hex(parts[2])[0 .. 15]
  let limit = snapshot.intValue(%*{}, keySecurityShareScrapeLimit)
  if quota(request, snapshot, "share", codeKey, "",
      limit * shareGlobalFactor, evictable = true):
    return true
  quota(request, snapshot, "share", codeKey & "|" & identity.key,
    identity.address, limit, evictable = true)

const
  conflictSqlStates = ["23001", "23503", "23505"]
  schemaSqlStates = ["23502", "23514", "54000"]
  formatSqlStates = ["22P02", "22007", "22008"]
  ## `55P03` is lock_not_available: a rating rebuild holds the community
  ## advisory lock, so a lock/unlock caller must get a retryable 503 rather
  ## than a 500 that reads like a defect in the request.
  busySqlStates = ["55P03"]

proc statusForSqlState*(state: string): int =
  ## One integrity violation, one status, decided once at the HTTP boundary.
  ## A duplicate or a missing/restricted reference is a conflict; a value the
  ## schema rejects or cannot cast is the caller's mistake, not an internal
  ## fault. A lock that is held by another transaction is temporary, so it is
  ## a 503. Everything else is a 500.
  if state in busySqlStates:
    503
  elif state in conflictSqlStates:
    409
  elif state in schemaSqlStates or state in formatSqlStates:
    400
  else:
    500

proc codeForSqlState*(state: string): string =
  case statusForSqlState(state)
  of 503: "UNAVAILABLE"
  of 409: "CONFLICT"
  of 400: "INVALID_INPUT"
  else: "INTERNAL"

proc detailForSqlState(state: string): string =
  ## The envelope keeps one sentence per cause, not one per status, because the
  ## legacy UI renders `detail` verbatim.
  if state in busySqlStates:
    "database is busy"
  elif state in formatSqlStates:
    "a value has the wrong format"
  elif state in schemaSqlStates:
    "a value does not satisfy the schema"
  elif state == "23505":
    "a value already exists"
  else:
    "the row is still referenced by other data"

proc dispatch(request: Request) =
  block:
    let path = request.path
    # The probes answer before any database or config read and outside the
    # quota. A liveness check that needs a database is a database probe, and a
    # burst must never answer 429 to the probe that decides a deploy is healthy.
    if path == "/healthz":
      send(request, 200, """{"status":"ok"}""")
      return
    if path == "/readyz":
      readyz(request)
      return
    let parts = path.split('/')
    let verb = request.httpMethod
    # The one access table: the test in modules/account compares this with
    # testdata/authz/matrix.yaml, so a class cannot change here alone.
    let access = operationAccess(verb, path)
    let snapshot = configSnapshot()
    # One label per request: the quota bucket and the counter label both use
    # the matched contract shape, never the raw path. An unmatched request gets
    # one shared label, so invented URLs cannot mint pinned buckets.
    if rejectLargeBody(request, snapshot):
      return
    if rejectCrossSite(request, snapshot):
      return
    # Resolve the address once: the identity pre-limit, the route budget and
    # the share budget all use it.
    let address = clientIp(request, trustedProxies())
    let now = utcNow().toTime.toUnixFloat
    let token = cookieValue(request, "majadu_session")
    # A cookie that was not validated in this window is a database lookup
    # candidate. Charge the address's pre-limit before it, so random cookies
    # are refused here and never reach `account.sessions`.
    if token.len > 0 and not application.identityCache.knows(token, now):
      if preLimit(request, snapshot, address, now):
        return
    let identity = requestIdentity(request, snapshot, address)
    if quota(request, snapshot, currentRouteLabel, identity,
        snapshot.intValue(%*{}, keySecurityRateLimitPerMinute)):
      return
    if rejectShareScrape(request, snapshot, identity):
      return
    if path.startsWith("/ops/"):
      if path == "/ops/ping" and request.httpMethod == "GET":
        opsPing(request)
      else:
        routeNotFound(request)
      return
    if path == "/version":
      if verb == "GET":
        jsonResponse(request, 200, %*{"version": appVersion, "commit": appCommit})
      else:
        problem(request, 405, "METHOD", "")
      return
    if outdatedClient(request):
      problem(request, 410, "CLIENT_OUTDATED",
        "this client speaks an older contract; reload the page")
      return
    case path
    of "/auth/start":
      if verb == "POST": startAuth(request, snapshot)
      else: problem(request, 405, "METHOD", "")
      return
    of "/auth/callback":
      if verb == "GET": finishAuth(request, snapshot) else: problem(request, 405, "METHOD", "")
      return
    of "/auth/logout":
      if verb == "POST": logout(request, snapshot) else: problem(request, 405, "METHOD", "")
      return
    of "/auth/me":
      if verb == "GET": me(request, snapshot) else: problem(request, 405, "METHOD", "")
      return
    of "/auth/sessions":
      if verb == "GET": listAuthSessions(request, snapshot)
      elif verb == "DELETE": revokeOtherSessions(request, snapshot)
      else: problem(request, 405, "METHOD", "")
      return
    of "/communities":
      if verb == "POST": createCommunity(request, snapshot)
      elif verb == "GET": listCommunities(request, snapshot)
      else: problem(request, 405, "METHOD", "")
      return
    of "/directory":
      if verb == "GET": directory(request, snapshot)
      else: problem(request, 405, "METHOD", "")
      return
    else: discard

    # /ws/c/{slug}/sessions/{id} and /ws/share/{code}
    if parts.len >= 3 and parts[1] == "ws":
      handleWebSocket(request, snapshot, parts)
      return
    # /c/{slug}/players[/{id}]
    if parts.len >= 4 and parts[1] == "c" and parts[3] == "players":
      let authorized = scoped(request, snapshot, parts[2], access)
      if authorized.isNone: return
      let (user, ctx) = authorized.get
      if parts.len == 4 and verb == "GET":
        listPlayersRoute(request, ctx, user.id, snapshot)
        return
      if parts.len == 4 and verb == "POST":
        createPlayerRoute(request, ctx, user, snapshot)
        return
      if parts.len == 5 and verb == "GET":
        getPlayerRoute(request, ctx, user, parts[4])
        return
      if parts.len == 5 and verb == "PATCH":
        patchPlayerRoute(request, ctx, user, parts[4], snapshot)
        return
      if parts.len == 5 and verb == "DELETE":
        deletePlayerRoute(request, ctx, user, parts[4])
        return
      if parts.len == 6 and parts[5] == "achievements" and verb == "GET":
        playerAchievements(request, ctx, parts[4], snapshot)
        return
      if parts.len == 6 and parts[5] == "stats" and verb == "GET":
        playerStats(request, ctx, parts[4], snapshot)
        return
      if parts.len == 6 and parts[5] == "merge" and verb == "POST":
        mergePlayerRoute(request, ctx, user, parts[4], snapshot)
        return
      if parts.len == 6 and parts[5] == "claims":
        if verb == "GET":
          listClaimsRoute(request, ctx, user, parts[4], snapshot)
          return
        if verb == "POST":
          submitClaim(request, ctx, user, parts[4])
          return
      if parts.len == 7 and parts[5] == "claims" and verb == "PATCH":
        decideClaim(request, ctx, user, parts[4], parts[6], snapshot)
        return
      if parts.len == 6 and parts[5] == "claim" and verb == "DELETE":
        releaseOwnClaim(request, ctx, user, parts[4])
        return
      if parts.len in [4, 5] or
         (parts.len == 6 and parts[5] in ["achievements", "stats", "merge",
                                         "claims", "claim"]) or
         (parts.len == 7 and parts[5] == "claims"):
        methodNotAllowed(request)
        return
    # /c/{slug}/sessions[/{id}[/share]]
    if parts.len >= 4 and parts[1] == "c" and parts[3] == "sessions":
      let authorized = scoped(request, snapshot, parts[2], access)
      if authorized.isNone: return
      let (user, ctx) = authorized.get
      if parts.len == 4 and verb == "GET":
        listSessions(request, ctx, snapshot)
        return
      if parts.len == 4 and verb == "POST":
        createSession(request, ctx, user, snapshot)
        return
      if parts.len == 5 and verb == "PATCH":
        patchSession(request, ctx, user, parts[4], snapshot)
        return
      if parts.len == 6 and parts[5] in ["lock", "unlock"] and verb == "POST":
        setSessionLock(request, ctx, user, parts[4], parts[5] == "lock", snapshot)
        return
      if parts.len == 5 and verb == "DELETE":
        deleteSession(request, ctx, user, parts[4])
        return
      if parts.len == 6 and parts[5] == "standings" and verb == "GET":
        getSessionStandingsRoute(request, ctx, parts[4])
        return
      if parts.len == 5 and verb == "GET":
        getSessionDetail(request, ctx, parts[4])
        return
      if parts.len == 6 and parts[5] == "share":
        if verb == "POST":
          createShare(request, ctx, user, parts[4], snapshot)
          return
        if verb == "GET":
          getShareLink(request, ctx, user, parts[4])
          return
        if verb == "DELETE":
          deleteShareLink(request, ctx, user, parts[4])
          return
      if parts.len == 6 and parts[5] == "swap" and verb == "POST":
        swapSession(request, ctx, user, parts[4], snapshot)
        return
      if parts.len == 6 and parts[5] == "ws-ticket" and verb == "POST":
        issueSessionTicket(request, ctx, user, parts[4], snapshot)
        return
      if parts.len == 6 and parts[5] == "rating":
        if verb in ["POST", "DELETE"]:
          if verb == "POST":
            ingestSessionRating(request, ctx, user, parts[4], snapshot)
          else:
            clearSessionRating(request, ctx, user, parts[4])
          return
      if parts.len == 6 and parts[5] == "schedule" and verb == "PUT":
        putScheduleRoute(request, ctx, user, parts[4], snapshot)
        return
      if parts.len == 6 and parts[5] == "absent" and verb == "PATCH":
        setAbsentRoute(request, ctx, user, parts[4], snapshot)
        return
      if parts.len == 7 and parts[5] == "games":
        if verb == "GET":
          getGameRoute(request, ctx, parts[4], parts[6])
          return
        if verb == "PATCH":
          setGameScoreRoute(request, ctx, user, parts[4], parts[6], snapshot)
          return
      if parts.len == 8 and parts[5] == "games" and parts[7] == "skip" and
         verb == "PATCH":
        skipGameRoute(request, ctx, user, parts[4], parts[6], snapshot)
        return
      if parts.len in [4, 5] or
         (parts.len == 6 and parts[5] in
           ["lock", "unlock", "standings", "share", "swap", "ws-ticket",
            "rating", "schedule", "absent"]) or
         (parts.len in [7, 8] and parts[5] == "games"):
        methodNotAllowed(request)
        return
    # /c/{slug}/tournaments[/{id}[/matches/{matchId}]]
    if parts.len >= 4 and parts[1] == "c" and parts[3] == "tournaments":
      let authorized = scoped(request, snapshot, parts[2], access)
      if authorized.isNone: return
      let (user, ctx) = authorized.get
      if parts.len == 4 and verb == "GET":
        listTournamentsRoute(request, ctx, snapshot)
        return
      if parts.len == 4 and verb == "POST":
        createTournamentRoute(request, ctx, user, snapshot)
        return
      if parts.len == 5 and verb == "GET":
        getTournamentRoute(request, ctx, parts[4])
        return
      if parts.len == 5 and verb == "PUT":
        putTournamentRoute(request, ctx, user, parts[4], snapshot)
        return
      if parts.len == 5 and verb == "DELETE":
        deleteTournamentRoute(request, ctx, user, parts[4])
        return
      if parts.len == 7 and parts[5] == "matches" and verb == "PATCH":
        patchTournamentMatchRoute(request, ctx, user, parts[4], parts[6], snapshot)
        return
      if parts.len == 6 and parts[5] == "rating" and verb in ["POST", "DELETE"]:
        if verb == "POST":
          ingestTournamentRating(request, ctx, user, parts[4], snapshot)
        else:
          clearTournamentRating(request, ctx, user, parts[4])
        return
      if parts.len in [4, 5] or
         (parts.len == 6 and parts[5] == "rating") or
         (parts.len == 7 and parts[5] == "matches"):
        methodNotAllowed(request)
        return
    # /c/{slug}/ratings/rebuild and /c/{slug}/rating-sources[/{id}]
    if parts.len >= 4 and parts[1] == "c" and
       parts[3] in ["ratings", "rating-sources"]:
      let admin = scoped(request, snapshot, parts[2], access)
      if admin.isNone: return
      if parts[3] == "ratings" and parts.len == 5 and parts[4] == "rebuild" and
         verb == "POST":
        rebuildRatings(request, admin.get[1], admin.get[0])
        return
      if parts[3] == "rating-sources" and parts.len == 4 and verb == "GET":
        listRatingSources(request, admin.get[1], snapshot)
        return
      if parts[3] == "rating-sources" and parts.len == 5 and verb == "PATCH":
        patchRatingSource(request, admin.get[1], admin.get[0], parts[4], snapshot)
        return
      if parts[3] == "rating-sources" and parts.len == 5 and verb == "DELETE":
        removeRatingSource(request, admin.get[1], admin.get[0], parts[4])
        return
      if (parts[3] == "ratings" and parts.len == 5 and parts[4] == "rebuild") or
         (parts[3] == "rating-sources" and parts.len in [4, 5]):
        methodNotAllowed(request)
        return
    # /invites/{token}/accept
    if parts.len == 4 and parts[1] == "invites" and parts[3] == "accept":
      if verb == "POST": acceptInvite(request, parts[2], snapshot)
      else: problem(request, 405, "METHOD", "")
      return
    # Anonymous join request: always the same 202, whatever the reason.
    if parts.len == 4 and parts[1] == "c" and parts[3] == "join-requests" and
       verb == "POST":
      requestJoin(request, parts[2], snapshot)
      return
    # /c/{slug}/members[/{userId}], /c/{slug}/join-requests[/{id}],
    # /c/{slug}/claims, /c/{slug}/invites, /c/{slug}/config
    if parts.len >= 4 and parts[1] == "c" and
       parts[3] in ["members", "join-requests", "claims", "invites", "config"]:
      # The member list and the effective config are member reads (export
      # sizes, page limits); every other operation in this family is admin.
      let authorized = scoped(request, snapshot, parts[2], access)
      if authorized.isNone: return
      let (user, ctx) = authorized.get
      if parts[3] == "members" and parts.len == 4 and verb == "GET":
        listMembers(request, ctx, snapshot)
        return
      if parts[3] == "config" and parts.len == 4 and verb == "GET":
        communityConfig(request, ctx, snapshot)
        return
      if parts[3] == "members" and parts.len == 5:
        if verb == "PATCH": patchMemberRole(request, ctx, user, parts[4], snapshot)
        elif verb == "DELETE": removeMember(request, ctx, user, parts[4])
        else: problem(request, 405, "METHOD", "")
        return
      if parts[3] == "join-requests" and parts.len == 4 and verb == "GET":
        listJoinRequests(request, ctx, snapshot)
        return
      if parts[3] == "join-requests" and parts.len == 5 and verb == "PATCH":
        decideJoinRequest(request, ctx, user, parts[4], snapshot)
        return
      if parts[3] == "claims" and parts.len == 4 and verb == "GET":
        listPendingClaims(request, ctx, snapshot)
        return
      if parts[3] == "invites" and parts.len == 4 and verb == "POST":
        createInvite(request, ctx, user, snapshot)
        return
    # /c/{slug}/settings
    if parts.len == 4 and parts[1] == "c" and parts[3] == "settings":
      if verb == "GET":
        let authorized = scoped(request, snapshot, parts[2], access)
        if authorized.isNone: return
        getCommunitySettings(request, authorized.get[1], snapshot)
      elif verb == "PATCH":
        # Settings are admin-only: a host raises scores, not the ceiling.
        let admin = scoped(request, snapshot, parts[2], access)
        if admin.isNone: return
        patchCommunitySettings(request, admin.get[1], admin.get[0], snapshot)
      else:
        problem(request, 405, "METHOD", "")
      return
    # /c/{slug}/rankings[/{playerId}]
    if parts.len in [4, 5] and parts[1] == "c" and parts[3] == "rankings":
      let authorized = scoped(request, snapshot, parts[2], access)
      if authorized.isNone: return
      let ctx = authorized.get[1]
      if parts.len == 4:
        communityBoard(request, ctx.communityId, ctx.timezone, snapshot,
          ctx.settings)
      else:
        rankingPlayer(request, ctx.communityId, ctx.timezone,
          parts[4], snapshot, ctx.settings)
      return
    # /s/{code} and /s/{code}/rankings
    if parts.len >= 3 and parts[1] == "s":
      let code = parts[2]
      if parts.len == 3:
        getShared(request, code)
        return
      if parts.len == 4 and parts[3] == "rankings":
        getSharedRankings(request, code, snapshot)
        return
      if parts.len == 5 and parts[3] == "rankings":
        getSharedRanking(request, code, parts[4], snapshot)
        return
      if parts.len == 4 and parts[3] == "ws-ticket" and verb == "POST":
        issueShareTicket(request, code, snapshot)
        return
    routeNotFound(request)

proc internalFailure(request: Request, error: ref Exception) =
  ## One envelope for a crash. Driver messages echo input values; the logger
  ## redacts and emits one JSON line, so a crafted path cannot forge log rows or
  ## leak a share code. The body names the request id, because the access line
  ## of a 500 and the audit rows of the write before it are found by that id.
  let requestId = currentRequestId()
  logError("request failed",
    [("error", error.msg), ("path", request.path),
     ("request_id", requestId)])
  problem(request, 500, "INTERNAL", "internal error",
    %*{"request_id": requestId})

proc guarded*(request: Request, body: proc()) =
  ## The last line of the request chain. Every branch answers with the one
  ## envelope, including a `Defect`: without this, an `IndexDefect` or a
  ## `KeyError` from a bad slice reaches mummy, which answers a plain 500 with
  ## no body, no code, no request id and no metric.
  try:
    body()
  except DbPoolTimeout:
    # The request never reached a query: answer with a retryable status instead
    # of holding the worker thread until the pool cycle unwedges.
    problem(request, 503, "UNAVAILABLE", "database is busy")
  except DbError as error:
    let status = statusForSqlState(error.sqlState)
    if status != 500:
      # PostgreSQL reports ON DELETE RESTRICT as 23001, not 23503; the player
      # delete used to fall through to the 500 branch because of that. Path and
      # body values that cannot become a uuid/date/time are cast before a row is
      # read, so 22xxx is the caller's mistake. Duplicates (23505) are conflicts.
      problem(request, status, codeForSqlState(error.sqlState),
        detailForSqlState(error.sqlState))
      return
    internalFailure(request, error)
  except shareStore.ShareKeyProblem as error:
    # BE-22: a live row references a key the process does not hold. The row
    # exists, so the answer is 503, never the 404 that reads "the link was never
    # created"; the metric and the log line name the link, not the code.
    shareKeyUnavailable(request, error)
  except Defect as error:
    internalFailure(request, error)
  except CatchableError as error:
    internalFailure(request, error)

proc route(request: Request) =
  # The quota label is derived from the contract shape before any database
  # read, so even a 500 from the config snapshot carries this request's label
  # instead of the previous one's.
  currentRouteLabel = quotaRoute(request.path)
  # One id per request: every audit row written while serving it and the
  # access-log line share it, so a 500 can be paired with the write before it.
  beginRequest()
  guarded(request, proc() = dispatch(request))

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
  let jobs = newRatingJobs(db)
  result = App(db: db, oidc: oidc, keyring: keyring, config: config,
      limiter: newLimiter(),
      identityCache: newIdentityCache(),
      ratingJobs: jobs,
      hub: newHub(db),
      cookieSecure: secureCookies(oidc),
      bootstrapOwner: getEnv("MAJADU_BOOTSTRAP_OWNER_EMAIL").strip().toLowerAscii())
  jobs.start()

proc identityLookups*(app: App): int =
  ## Database lookups performed to turn a token into a user id. The rate-limit
  ## suite reads this to prove a rejected cookie did not query the database.
  app.identityCache.identityLookups()

proc install*(app: App) =
  application = app
  installHub(app.hub)

proc rotateActiveKey*(keyId: string) =
  ## Test seam for the documented rotation path: production loads the keyring
  ## once at boot, and an in-flight flow must still decrypt with the key that
  ## wrote it. Rejects an id the keyring does not hold, like `decryptWith`.
  if application.isNil:
    raise newException(ValueError, "application is not installed")
  for (candidate, _) in application.keyring.keys:
    if candidate == keyId:
      application.keyring.active = keyId
      return
  raise newException(ValueError, "unknown key id: " & keyId)

proc handler*(): RequestHandler =
  ## The App lives in a process-wide ref shared by every worker thread. Mummy
  ## requires a gcsafe handler; the cast is the single audited boundary, because
  ## `application` is assigned once at boot and never mutated afterwards.
  result = proc(request: Request) {.gcsafe.} =
    {.cast(gcsafe).}:
      route(request)
