when defined(ssl):
  import std/httpclient
import std/[json, locks, os, strutils, times, uri]
import clock
import http_min
import jwt_rs256

type
  OidcConfig* = object
    authorizeUrl*: string
    tokenUrl*: string
    jwksUrl*: string
    issuer*: string
    clientId*: string
    clientSecret*: string
    redirectUri*: string

  JwksSnapshot* = object
    ## One immutable view of the provider keys. A reader takes a copy under the
    ## lock and never sees a half-written key set.
    keys*: seq[Jwk]
    fetchedAt*: float

  JwksFetcher* = proc(config: OidcConfig): seq[Jwk]

## How long the provider key set is reused before the next login refetches it.
## A named constant rather than a literal so the one hour is not read as an
## accident of the comparison it appears in (SQ-20).
const jwksTtlSeconds = 3600

var
  ## Initialised at module load, before any worker thread exists. There is no
  ## lazy `initLock` race between two concurrent first logins.
  cacheLock: Lock
  cache: JwksSnapshot
  fetcher: JwksFetcher

initLock(cacheLock)

proc loadOidcConfig*(): OidcConfig =
  result.authorizeUrl = getEnv("OIDC_AUTHORIZE_URL", "https://accounts.google.com/o/oauth2/v2/auth")
  result.tokenUrl = getEnv("OIDC_TOKEN_URL", "https://oauth2.googleapis.com/token")
  result.jwksUrl = getEnv("OIDC_JWKS_URL", "https://www.googleapis.com/oauth2/v3/certs")
  result.issuer = getEnv("OIDC_ISSUER", "https://accounts.google.com")
  result.clientId = getEnv("OIDC_CLIENT_ID")
  result.clientSecret = getEnv("OIDC_CLIENT_SECRET")
  result.redirectUri = getEnv("OIDC_REDIRECT_URI")
  if result.clientId.len == 0 or result.redirectUri.len == 0:
    raise newException(ValueError, "OIDC_CLIENT_ID and OIDC_REDIRECT_URI are required")

proc fetchRaw(url, verb, body: string, contentType = ""): string =
  var status: int
  if url.startsWith("http://"):
    let headers = if contentType.len == 0: @[] else: @[("Content-Type", contentType)]
    (status, result) = httpRequest(url, verb, body, headers)
  else:
    when defined(ssl):
      var client = newHttpClient(timeout = 10000)
      defer: client.close()
      var headers = newHttpHeaders()
      if contentType.len > 0:
        headers["Content-Type"] = contentType
      let response = client.request(url, httpMethod = (if verb == "POST": HttpPost else: HttpGet),
        body = body, headers = headers)
      status = response.code.int
      result = response.body
    else:
      raise newException(ValueError, "https OIDC requires a build with -d:ssl")
  if status < 200 or status >= 300:
    raise newException(ValueError, "OIDC endpoint returned " & $status)

proc fetchJwksFromProvider(config: OidcConfig): seq[Jwk] =
  parseJwks(parseJson(fetchRaw(config.jwksUrl, "GET", "")))

fetcher = fetchJwksFromProvider

proc authorizeUrl*(config: OidcConfig, state, nonce, challenge: string): string =
  let separator = if '?' in config.authorizeUrl: "&" else: "?"
  config.authorizeUrl & separator &
    "client_id=" & encodeUrl(config.clientId) &
    "&redirect_uri=" & encodeUrl(config.redirectUri) &
    "&response_type=code&scope=openid%20email%20profile" &
    "&state=" & encodeUrl(state) &
    "&nonce=" & encodeUrl(nonce) &
    "&code_challenge=" & encodeUrl(challenge) &
    "&code_challenge_method=S256"

proc tokenRequestBody*(config: OidcConfig, code, verifier: string): string =
  ## The token endpoint exchange. A Google "Web application" client is
  ## confidential and rejects the request without its secret; a public client
  ## has none, so the parameter is only sent when a secret is configured.
  result = "grant_type=authorization_code&code=" & encodeUrl(code) &
    "&client_id=" & encodeUrl(config.clientId) &
    "&redirect_uri=" & encodeUrl(config.redirectUri) &
    "&code_verifier=" & encodeUrl(verifier)
  if config.clientSecret.len > 0:
    result.add("&client_secret=" & encodeUrl(config.clientSecret))

proc exchangeCode*(config: OidcConfig, code, verifier: string): string =
  let document = parseJson(fetchRaw(config.tokenUrl, "POST",
    tokenRequestBody(config, code, verifier),
    "application/x-www-form-urlencoded"))
  if not document.hasKey("id_token"):
    raise newException(ValueError, "token endpoint returned no id_token")
  document["id_token"].getStr()

proc cacheSnapshot(): JwksSnapshot =
  acquire(cacheLock)
  try:
    result = cache
  finally:
    release(cacheLock)

proc storeSnapshot(snapshot: JwksSnapshot) =
  acquire(cacheLock)
  try:
    cache = snapshot
  finally:
    release(cacheLock)

proc stale(keys: seq[Jwk], fetchedAt, now: float): bool =
  keys.len == 0 or now - fetchedAt > jwksTtlSeconds.float

proc jwks*(config: OidcConfig): seq[Jwk] =
  ## The cached keys, refreshed once the hour has passed. The provider fetch is
  ## never performed while the cache lock is held, so one slow IdP round trip
  ## cannot serialise every login; the snapshot is swapped under the lock only
  ## after the fetch returns.
  let now = utcNow().toTime.toUnixFloat
  let current = cacheSnapshot()
  if not stale(current.keys, current.fetchedAt, now):
    return current.keys
  var fetched = fetcher(config)
  let fresh = JwksSnapshot(keys: fetched, fetchedAt: utcNow().toTime.toUnixFloat)
  # A concurrent reader may have refreshed while this one fetched. Keeping the
  # newer snapshot avoids replacing fresh keys with an older response.
  acquire(cacheLock)
  try:
    if stale(cache.keys, cache.fetchedAt, now):
      cache = fresh
    result = cache.keys
  finally:
    release(cacheLock)

proc refreshJwks(config: OidcConfig): seq[Jwk] =
  ## One forced fetch. Called when a token names a key id the snapshot does not
  ## hold, which is what a provider rotation looks like before the hour ends.
  let keys = fetcher(config)
  let fresh = JwksSnapshot(keys: keys, fetchedAt: utcNow().toTime.toUnixFloat)
  storeSnapshot(fresh)
  keys

proc verifyIdTokenWithRefresh*(config: OidcConfig, token, issuer, audience,
                               nonce: string, nowUnix: int64): JsonNode =
  ## Verifies against the current keys, and refreshes exactly once when the
  ## token names an unknown key id. A provider rotation must not fail every
  ## login until the hourly cache entry ages out.
  let keys = jwks(config)
  try:
    return verifyIdToken(token, keys, issuer, audience, nonce, nowUnix)
  except JwtError as error:
    if error.msg != "unknown JWKS kid":
      raise
  verifyIdToken(token, refreshJwks(config), issuer, audience, nonce, nowUnix)

proc setJwksFetcher*(value: JwksFetcher) =
  ## Test seam: the fetch is a pure function of the config, so a suite can
  ## replace it with a fake and count the fetches without a network.
  fetcher = value

proc resetJwksCache*() =
  ## Test seam: starts the next case from an empty snapshot.
  storeSnapshot(JwksSnapshot())
