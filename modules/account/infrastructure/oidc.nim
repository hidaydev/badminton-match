when defined(ssl):
  import std/httpclient
import std/[json, locks, os, strutils, times, uri]
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

  JwksCache = object
    lock: Lock
    keys: seq[Jwk]
    fetchedAt: float

var cache: JwksCache
var cacheReady = false

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

proc jwks*(config: OidcConfig): seq[Jwk] =
  if not cacheReady:
    initLock(cache.lock)
    cacheReady = true
  acquire(cache.lock)
  try:
    if cache.keys.len == 0 or epochTime() - cache.fetchedAt > 3600:
      let document = parseJson(fetchRaw(config.jwksUrl, "GET", ""))
      cache.keys = parseJwks(document)
      cache.fetchedAt = epochTime()
    result = cache.keys
  finally:
    release(cache.lock)
