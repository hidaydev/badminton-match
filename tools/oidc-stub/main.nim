import std/[atomics, base64, json, os, osproc, strutils, times, uri]
import mummy

const
  keyPath = "tools/oidc-stub/test_key.pem"
  kid = "test-1"

proc b64url(data: string): string =
  result = encode(data)
  result = result.replace('+', '-').replace('/', '_').strip(chars = {'='})

proc b64urlDecode(data: string): string =
  var padded = data.replace('-', '+').replace('_', '/')
  while padded.len mod 4 != 0:
    padded.add('=')
  decode(padded)

var signCounter: Atomic[int]

proc sign(input: string): string =
  ## The stub serves requests on several threads, so each call gets its own
  ## files: sharing one path let two token exchanges overwrite each other and
  ## produced signatures for the wrong payload.
  let dir = getTempDir() / ("oidc-stub-" & $getCurrentProcessId() & "-" &
    $fetchAdd(signCounter, 1))
  createDir(dir)
  let dataPath = dir / "input"
  let sigPath = dir / "signature"
  try:
    writeFile(dataPath, input)
    let command = "openssl dgst -sha256 -sign " & quoteShell(keyPath) &
      " -out " & quoteShell(sigPath) & " " & quoteShell(dataPath)
    let (output, code) = execCmdEx(command)
    if code != 0:
      raise newException(IOError, "openssl signing failed: " & output)
    result = b64url(readFile(sigPath))
  finally:
    removeFile(dataPath)
    removeFile(sigPath)
    removeDir(dir)

proc issueToken(issuer, audience, subject, email, nonce: string): string =
  let now = epochTime().int64
  let header = %*{"alg": "RS256", "kid": kid, "typ": "JWT"}
  let payload = %*{
    "iss": issuer,
    "aud": audience,
    "sub": subject,
    "email": email,
    "email_verified": true,
    "nonce": nonce,
    "iat": now,
    "exp": now + 3600,
  }
  let signingInput = b64url($header) & "." & b64url($payload)
  signingInput & "." & sign(signingInput)

proc isLocalRedirect(target: string): bool =
  try:
    let parsed = parseUri(target)
    parsed.scheme in ["http", "https"] and
      parsed.hostname in ["127.0.0.1", "localhost"]
  except CatchableError:
    false

proc addQuery(target, key, value: string): string =
  let separator = if '?' in target: "&" else: "?"
  target & separator & key & "=" & encodeUrl(value)

proc handle(request: Request) {.gcsafe.} =
  case request.path
  of "/healthz":
    request.respond(200, @[("Content-Type", "application/json")], """{"status":"ok"}""")
  of "/.well-known/openid-configuration":
    let issuer = getEnv("OIDC_STUB_ISSUER", "http://127.0.0.1:9090")
    let body = %*{
      "issuer": issuer,
      "authorization_endpoint": issuer & "/authorize",
      "token_endpoint": issuer & "/token",
      "jwks_uri": issuer & "/jwks",
      "response_types_supported": ["code"],
      "subject_types_supported": ["public"],
      "id_token_signing_alg_values_supported": ["RS256"],
    }
    request.respond(200, @[("Content-Type", "application/json")], $body)
  of "/jwks":
    request.respond(200, @[("Content-Type", "application/json")], readFile("tools/oidc-stub/jwks.json"))
  of "/authorize":
    let redirectUri = request.queryParams["redirect_uri"]
    if redirectUri.len == 0 or not isLocalRedirect(redirectUri):
      request.respond(400, @[("Content-Type", "application/json")],
        """{"error":"invalid_redirect_uri"}""")
      return
    let claims = %*{
      "sub": if request.queryParams["sub"].len > 0: request.queryParams["sub"] else: "stub-user-1",
      "email": if request.queryParams["login_hint"].len > 0: request.queryParams["login_hint"] else: "stub@example.com",
      "nonce": request.queryParams["nonce"],
    }
    var location = addQuery(redirectUri, "code", b64url($claims))
    if request.queryParams["state"].len > 0:
      location = addQuery(location, "state", request.queryParams["state"])
    request.respond(302, @[("Location", location)], "")
  of "/token":
    var code = ""
    for (key, value) in decodeQuery(request.body):
      if key == "code":
        code = value
    if code.len == 0:
      request.respond(400, @[("Content-Type", "application/json")],
        """{"error":"invalid_request"}""")
      return
    try:
      let claims = parseJson(b64urlDecode(code))
      let issuer = getEnv("OIDC_STUB_ISSUER", "http://127.0.0.1:9090")
      let audience = getEnv("OIDC_STUB_CLIENT_ID", "majadu-dev")
      let token = issueToken(
        issuer,
        audience,
        claims["sub"].getStr(),
        claims["email"].getStr(),
        claims["nonce"].getStr(),
      )
      let body = %*{"id_token": token, "token_type": "Bearer", "expires_in": 3600}
      request.respond(200, @[("Content-Type", "application/json")], $body)
    except CatchableError:
      request.respond(400, @[("Content-Type", "application/json")],
        """{"error":"invalid_grant"}""")
  else:
    request.respond(404, @[("Content-Type", "application/json")], """{"error":"not_found"}""")

proc main() =
  let port = parseInt(getEnv("OIDC_STUB_PORT", "9090"))
  if not fileExists(keyPath):
    stderr.writeLine "oidc-stub: missing " & keyPath
    quit(1)
  let server = newServer(handle, workerThreads = 2)
  echo "oidc-stub: listening on " & $port
  server.serve(Port(port), "127.0.0.1")

when isMainModule:
  main()
