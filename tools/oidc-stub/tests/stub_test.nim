## TL-16: the OIDC stub's HTTP contract, proved by running the compiled stub.
##
## `isLocalRedirect`, `addQuery`, `b64url` and `handle` are private, and D-5
## allows one export per item, already spent on `matches` in the mock API. Every
## case here therefore drives the routes the stub serves, and the signature case
## verifies a real RS256 token against `test_key.pub.pem`, which is what
## `tools/oidc-stub/smoke.sh` does by hand.
##
## The stub reads its key and its JWKS file through relative paths, so it is
## started with the repository root as its working directory. The port is
## ephemeral and `OIDC_STUB_PORT`/`OIDC_STUB_ISSUER` are set for each start.
import std/[base64, httpclient, json, net, os, osproc, strutils, unittest, uri]

const
  binaryEnv = "OIDC_STUB_BIN"
  keyPath = "tools/oidc-stub/test_key.pem"
  publicKeyPath = "tools/oidc-stub/test_key.pub.pem"
  jwksPath = "tools/oidc-stub/jwks.json"
  clientId = "majadu-stub-suite"
  callback = "http://127.0.0.1:5173/cb"

var
  repo = ""
  base = ""
  stubProcess: Process

proc findRepo(): string =
  var dir = getCurrentDir()
  for _ in 0 ..< 8:
    if fileExists(dir / keyPath):
      return dir
    let parent = parentDir(dir)
    if parent == dir:
      break
    dir = parent
  # The suite can be started from an unrelated directory; the source path is
  # always inside the repository.
  dir = currentSourcePath().parentDir
  for _ in 0 ..< 8:
    if fileExists(dir / keyPath):
      return dir
    let parent = parentDir(dir)
    if parent == dir:
      break
    dir = parent
  raise newException(IOError, "cannot find the repository root: " & keyPath &
    " is missing")

proc stubBinary(): string =
  ## `OIDC_STUB_BIN` lets CI reuse a binary it already built; otherwise the
  ## stub is compiled once, in a cache of its own, as
  ## `tools/oidc-stub/smoke.sh` does.
  var built {.global.}: string
  if built.len > 0:
    return built
  let fromEnv = getEnv(binaryEnv)
  if fromEnv.len > 0 and fileExists(fromEnv):
    built = fromEnv
    return built
  let directory = getTempDir() / ("majadu-oidc-stub-" & $getCurrentProcessId())
  createDir(directory)
  built = directory / "oidc-stub"
  let (output, code) = execCmdEx("nim c --hints:off --nimcache:" &
    quoteShell(directory / "nimcache") & " -o:" & quoteShell(built) & " " &
    quoteShell(repo / "tools/oidc-stub/main.nim"), workingDir = repo)
  if code != 0 or not fileExists(built):
    raise newException(IOError, "cannot build the OIDC stub:\n" & output)
  built

proc freePort(): Port =
  var socket = newSocket()
  defer: socket.close()
  socket.bindAddr(Port(0), "127.0.0.1")
  let (_, bound) = socket.getLocalAddr()
  bound

proc healthy(url: string): bool =
  try:
    let client = newHttpClient(timeout = 500)
    defer: client.close()
    result = client.get(url & "/healthz").code.int == 200
  except CatchableError:
    result = false

proc boot(): tuple[process: Process, base: string] =
  ## A random high port on the loopback interface, retried once when the first
  ## choice is taken between the probe and the bind.
  let binary = stubBinary()
  var reason = ""
  for attempt in 0 ..< 2:
    let port = freePort()
    let url = "http://127.0.0.1:" & $int(port)
    putEnv("OIDC_STUB_PORT", $int(port))
    putEnv("OIDC_STUB_ISSUER", url)
    putEnv("OIDC_STUB_CLIENT_ID", clientId)
    let process = startProcess(binary, workingDir = repo, args = [])
    var up = false
    for _ in 0 ..< 100:
      if healthy(url):
        up = true
        break
      if not process.running:
        break
      sleep(50)
    if up:
      return (process, url)
    reason = "attempt " & $(attempt + 1) & " on port " & $int(port) &
      " did not answer /healthz"
    if process.running:
      terminate(process)
      discard waitForExit(process, 2000)
  raise newException(IOError, "the OIDC stub did not start: " & reason)

proc stopStub() =
  if stubProcess != nil and stubProcess.running:
    terminate(stubProcess)
    discard waitForExit(stubProcess, 2000)

proc call(path: string): Response =
  let client = newHttpClient(timeout = 5000, maxRedirects = 0)
  defer: client.close()
  client.get(base & path)

proc header(response: Response, name: string): string =
  ## `headers[name]` yields the list of values (`HttpHeaderValues`); the string
  ## converter is forced here so the cases compare against the one value the
  ## stub sends instead of `contains` on that list.
  result = response.headers[name]

proc postToken(body: string): Response =
  let client = newHttpClient(timeout = 5000, maxRedirects = 0)
  defer: client.close()
  client.post(base & "/token", body = body)

proc exchange(code: string): Response =
  postToken("grant_type=authorization_code&code=" & encodeUrl(code))

proc queryValue(url, key: string): string =
  for pair in parseUri(url).query.split('&'):
    let at = pair.find('=')
    if at > 0 and decodeUrl(pair[0 ..< at]) == key:
      return decodeUrl(pair[at + 1 .. ^1])

proc authorizeQuery(params: openArray[(string, string)]): string =
  var pairs: seq[string]
  for (key, value) in params:
    pairs.add key & "=" & encodeUrl(value)
  pairs.join("&")

proc authorize(params: openArray[(string, string)]): Response =
  call("/authorize?" & authorizeQuery(params))

proc codeFor(params: openArray[(string, string)]): string =
  let response = authorize(params)
  doAssert response.code.int == 302, response.body
  queryValue(response.header("Location"), "code")

proc toB64Url(data: string): string =
  result = encode(data).replace('+', '-').replace('/', '_').strip(chars = {'='})

proc fromB64Url(text: string): string =
  var padded = text.replace('-', '+').replace('_', '/')
  while padded.len mod 4 != 0:
    padded.add '='
  decode(padded)

proc payloadOf(token: string): JsonNode =
  let parts = token.split('.')
  doAssert parts.len == 3, token
  parseJson(fromB64Url(parts[1]))

proc tokenFor(params: openArray[(string, string)]): string =
  let response = exchange(codeFor(params))
  doAssert response.code.int == 200, response.body
  parseJson(response.body)["id_token"].getStr()

proc verify(signingInput, signature: string):
    tuple[output: string, exitCode: int] =
  var directory {.global.}: string
  if directory.len == 0:
    directory = getTempDir() / ("majadu-oidc-verify-" & $getCurrentProcessId())
    createDir(directory)
  let inputPath = directory / "input"
  let signaturePath = directory / "signature"
  writeFile(inputPath, signingInput)
  writeFile(signaturePath, signature)
  execCmdEx("openssl dgst -sha256 -verify " &
    quoteShell(repo / publicKeyPath) & " -signature " &
    quoteShell(signaturePath) & " " & quoteShell(inputPath))

repo = findRepo()
(stubProcess, base) = boot()

suite "oidc stub: redirect guard":
  test "authorize redirects a loopback callback and echoes the state":
    for target in [callback, "http://localhost/cb"]:
      let response = authorize([("redirect_uri", target), ("state", "s-1"),
        ("nonce", "n-1")])
      check response.code.int == 302
      let location = response.header("Location")
      check location.startsWith(target & "?code=")
      check location.contains("&state=s-1")

  test "authorize refuses a foreign, relative or unparsable redirect":
    # Nim's `parseUri` does not raise for these; they arrive with no scheme or
    # with a foreign host, and the host check is what refuses them.
    for target in ["https://evil.example/cb", "//evil.example/cb", "/cb",
                   "not a uri", "http://[::1", "http://127.0.0.2/cb"]:
      checkpoint("redirect_uri=" & target)
      let response = authorize([("redirect_uri", target), ("state", "s")])
      check response.code.int == 400
      check response.body.contains("invalid_redirect_uri")

  test "authorize refuses a request with no redirect_uri":
    let response = call("/authorize?state=s")
    check response.code.int == 400
    check response.body.contains("invalid_redirect_uri")

  test "addQuery appends with ? on a bare URL and & on a URL with a query":
    let bare = authorize([("redirect_uri", callback)])
    check bare.code.int == 302
    check bare.header("Location").startsWith(callback & "?code=")
    let withQuery = authorize([("redirect_uri", callback & "?x=1")])
    check withQuery.code.int == 302
    check withQuery.header("Location").startsWith(callback & "?x=1&code=")

  test "the echoed state is URL-encoded":
    let response = authorize([("redirect_uri", callback),
      ("state", "a&b/c")])
    check response.code.int == 302
    check response.header("Location").contains("state=a%26b%2Fc")

  test "authorize without a nonce still redirects with a code":
    let response = authorize([("redirect_uri", callback)])
    check response.code.int == 302
    let location = response.header("Location")
    check location.startsWith(callback & "?code=")
    check queryValue(location, "code").len > 0
    check not location.contains("state=")

suite "oidc stub: token exchange":
  test "/token without a code returns invalid_request":
    let response = postToken("grant_type=authorization_code")
    check response.code.int == 400
    check response.body.contains("invalid_request")

  test "/token with a garbage code returns invalid_grant":
    for junk in ["not-base64-!", "aGVsbG8"]:
      checkpoint("code=" & junk)
      let response = exchange(junk)
      check response.code.int == 400
      check response.body.contains("invalid_grant")

  test "the authorization code is unpadded base64url":
    let code = codeFor([("redirect_uri", callback), ("state", "st"),
      ("nonce", "n-9"), ("sub", "person-7"),
      ("login_hint", "seven@example.com")])
    check code.len > 0
    check not code.contains('=')
    check not code.contains('+')
    check not code.contains('/')
    for character in code:
      check character in {'A' .. 'Z', 'a' .. 'z', '0' .. '9', '-', '_'}
    let claims = parseJson(fromB64Url(code))
    check claims["sub"].getStr() == "person-7"
    check claims["email"].getStr() == "seven@example.com"
    check claims["nonce"].getStr() == "n-9"

  test "b64urlDecode accepts a code whose base64 padding was stripped":
    var code = ""
    for extra in 0 ..< 8:
      let claims = %*{"sub": "unpadded", "email": "u@example.com",
        "nonce": "x".repeat(extra)}
      code = toB64Url($claims)
      if code.len mod 4 != 0:
        break
    # Padding is only required for some lengths; the loop picks one of those.
    check code.len mod 4 != 0
    let response = exchange(code)
    check response.code.int == 200
    let token = parseJson(response.body)["id_token"].getStr()
    check payloadOf(token)["sub"].getStr() == "unpadded"

  test "the issued id_token verifies with test_key.pub.pem":
    let token = tokenFor([("redirect_uri", callback), ("state", "s"),
      ("nonce", "n-1"), ("sub", "person-1"),
      ("login_hint", "one@example.com")])
    let parts = token.split('.')
    check parts.len == 3
    let header = parseJson(fromB64Url(parts[0]))
    check header["alg"].getStr() == "RS256"
    check header["kid"].getStr() == "test-1"
    let payload = payloadOf(token)
    check payload["iss"].getStr() == base
    check payload["aud"].getStr() == clientId
    check payload["sub"].getStr() == "person-1"
    check payload["email"].getStr() == "one@example.com"
    check payload["email_verified"].getBool()
    check payload["nonce"].getStr() == "n-1"
    check payload["exp"].getInt() - payload["iat"].getInt() == 3600
    let verified = verify(parts[0] & "." & parts[1], fromB64Url(parts[2]))
    check verified.exitCode == 0
    check verified.output.contains("Verified OK")

  test "a tampered id_token fails the same verification":
    let token = tokenFor([("redirect_uri", callback), ("nonce", "n-2")])
    let parts = token.split('.')
    var tampered = parts[1]
    let middle = tampered.len div 2
    tampered[middle] = if tampered[middle] == 'A': 'B' else: 'A'
    check tampered != parts[1]
    let rejected = verify(parts[0] & "." & tampered, fromB64Url(parts[2]))
    check rejected.exitCode != 0
    check not rejected.output.contains("Verified OK")
    # The untouched token still verifies, so the refusal is the tamper.
    check verify(parts[0] & "." & parts[1], fromB64Url(parts[2])).exitCode == 0

suite "oidc stub: metadata":
  test "/jwks serves the committed key set":
    let response = call("/jwks")
    check response.code.int == 200
    let served = parseJson(response.body)
    check served == parseJson(readFile(repo / jwksPath))
    check served["keys"][0]["kid"].getStr() == "test-1"
    check served["keys"][0]["alg"].getStr() == "RS256"

  test "the discovery document names the issuer and the three endpoints":
    let response = call("/.well-known/openid-configuration")
    check response.code.int == 200
    let document = parseJson(response.body)
    check document["issuer"].getStr() == base
    check document["authorization_endpoint"].getStr() == base & "/authorize"
    check document["token_endpoint"].getStr() == base & "/token"
    check document["jwks_uri"].getStr() == base & "/jwks"
    check document["id_token_signing_alg_values_supported"][0].getStr() == "RS256"

  test "an unknown path returns 404":
    let response = call("/not-a-route")
    check response.code.int == 404
    check response.body.contains("not_found")

stopStub()