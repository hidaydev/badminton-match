import std/[base64, json, os, osproc, strutils, times, unittest]
import ../../infrastructure/jwt_rs256

const
  keyPath = "tools/oidc-stub/test_key.pem"
  jwksPath = "tools/oidc-stub/jwks.json"

proc b64url(data: string): string =
  result = encode(data).replace('+', '-').replace('/', '_')
  result = result.strip(chars = {'='})

proc sign(input: string): string =
  let inputPath = getTempDir() / "jwt-test-input"
  let sigPath = getTempDir() / "jwt-test-sig"
  writeFile(inputPath, input)
  let (output, code) = execCmdEx(
    "openssl dgst -sha256 -sign " & quoteShell(keyPath) &
    " -out " & quoteShell(sigPath) & " " & quoteShell(inputPath))
  if code != 0:
    raise newException(IOError, output)
  b64url(readFile(sigPath))

proc makeToken(nonce: string, expires: int64): string =
  let header = %*{"alg": "RS256", "kid": "test-1", "typ": "JWT"}
  let claims = %*{
    "iss": "http://issuer.test",
    "aud": "majadu-dev",
    "sub": "user-1",
    "email": "test@example.com",
    "nonce": nonce,
    "exp": expires,
  }
  let signingInput = b64url($header) & "." & b64url($claims)
  signingInput & "." & sign(signingInput)

suite "RS256 verification":
  test "accepts a signed token and rejects tampering":
    let jwks = parseJwks(parseFile(jwksPath))
    let token = makeToken("nonce-1", epochTime().int64 + 300)
    let claims = verifyIdToken(token, jwks, "http://issuer.test", "majadu-dev",
      "nonce-1", epochTime().int64)
    check claims["email"].getStr() == "test@example.com"

  test "rejects a wrong nonce":
    let jwks = parseJwks(parseFile(jwksPath))
    let token = makeToken("nonce-1", epochTime().int64 + 300)
    expect JwtError:
      discard verifyIdToken(token, jwks, "http://issuer.test", "majadu-dev",
        "other", epochTime().int64)

  test "rejects an expired token":
    let jwks = parseJwks(parseFile(jwksPath))
    let token = makeToken("nonce-1", epochTime().int64 - 10)
    expect JwtError:
      discard verifyIdToken(token, jwks, "http://issuer.test", "majadu-dev",
        "nonce-1", epochTime().int64)

  test "rejects a tampered signature":
    let jwks = parseJwks(parseFile(jwksPath))
    let token = makeToken("nonce-1", epochTime().int64 + 300)
    var parts = token.split('.')
    parts[2] = (if parts[2][0] == 'A': "B" else: "A") & parts[2][1 .. ^1]
    expect JwtError:
      discard verifyIdToken(parts.join("."), jwks, "http://issuer.test",
        "majadu-dev", "nonce-1", epochTime().int64)
