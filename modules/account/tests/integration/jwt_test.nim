import std/[base64, json, os, osproc, strutils, unittest]
import ../../infrastructure/jwt_rs256

const
  keyPath = "tools/oidc-stub/test_key.pem"
  jwksPath = "tools/oidc-stub/jwks.json"
  # A fixed instant, so `exp` is an absolute value the verifier is given rather
  # than a wall-clock reading. R-07: no test in this file calls epochTime().
  issuedAt = 1_800_000_000'i64

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

proc signClaims(claims: JsonNode): string =
  let header = %*{"alg": "RS256", "kid": "test-1", "typ": "JWT"}
  let signingInput = b64url($header) & "." & b64url($claims)
  signingInput & "." & sign(signingInput)

proc makeToken(nonce: string, expires: int64): string =
  signClaims(%*{
    "iss": "http://issuer.test",
    "aud": "majadu-dev",
    "sub": "user-1",
    "email": "test@example.com",
    "email_verified": true,
    "nonce": nonce,
    "exp": expires,
  })

suite "RS256 verification":
  test "accepts a signed token and rejects tampering":
    let jwks = parseJwks(parseFile(jwksPath))
    let token = makeToken("nonce-1", issuedAt + 300)
    let claims = verifyIdToken(token, jwks, "http://issuer.test", "majadu-dev",
      "nonce-1", issuedAt)
    check claims["email"].getStr() == "test@example.com"

  test "rejects an email the provider has not verified":
    let jwks = parseJwks(parseFile(jwksPath))
    let now = issuedAt
    for claims in [
      %*{"iss": "http://issuer.test", "aud": "majadu-dev", "sub": "user-1",
         "email": "test@example.com", "email_verified": false,
         "nonce": "nonce-1", "exp": now + 300},
      %*{"iss": "http://issuer.test", "aud": "majadu-dev", "sub": "user-1",
         "email": "test@example.com", "nonce": "nonce-1", "exp": now + 300},
      %*{"iss": "http://issuer.test", "aud": "majadu-dev", "sub": "user-1",
         "email": "test@example.com", "email_verified": "true",
         "nonce": "nonce-1", "exp": now + 300},
    ]:
      expect JwtError:
        discard verifyIdToken(signClaims(claims), jwks, "http://issuer.test",
          "majadu-dev", "nonce-1", now)

  test "rejects a token minted for another client of the same issuer":
    let jwks = parseJwks(parseFile(jwksPath))
    let now = issuedAt
    let claims = %*{"iss": "http://issuer.test", "aud": "majadu-dev",
      "azp": "some-other-client", "sub": "user-1",
      "email": "test@example.com", "email_verified": true,
      "nonce": "nonce-1", "exp": now + 300}
    expect JwtError:
      discard verifyIdToken(signClaims(claims), jwks, "http://issuer.test",
        "majadu-dev", "nonce-1", now)
    # A token that names this client is accepted.
    let ours = %*{"iss": "http://issuer.test", "aud": "majadu-dev",
      "azp": "majadu-dev", "sub": "user-1", "email": "test@example.com",
      "email_verified": true, "nonce": "nonce-1", "exp": now + 300}
    check verifyIdToken(signClaims(ours), jwks, "http://issuer.test",
      "majadu-dev", "nonce-1", now)["sub"].getStr() == "user-1"

  test "rejects a wrong nonce":
    let jwks = parseJwks(parseFile(jwksPath))
    let token = makeToken("nonce-1", issuedAt + 300)
    expect JwtError:
      discard verifyIdToken(token, jwks, "http://issuer.test", "majadu-dev",
        "other", issuedAt)

  test "rejects an expired token":
    let jwks = parseJwks(parseFile(jwksPath))
    let token = makeToken("nonce-1", issuedAt - 10)
    expect JwtError:
      discard verifyIdToken(token, jwks, "http://issuer.test", "majadu-dev",
        "nonce-1", issuedAt)

  test "rejects a tampered signature":
    let jwks = parseJwks(parseFile(jwksPath))
    let token = makeToken("nonce-1", issuedAt + 300)
    var parts = token.split('.')
    parts[2] = (if parts[2][0] == 'A': "B" else: "A") & parts[2][1 .. ^1]
    expect JwtError:
      discard verifyIdToken(parts.join("."), jwks, "http://issuer.test",
        "majadu-dev", "nonce-1", issuedAt)
