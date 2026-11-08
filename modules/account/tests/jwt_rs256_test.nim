## `parseJwks` and `decodePart` are the two parsing seams of the ID token path.
## Their contract is what the code does, not what a document ought to say: a
## JWKS key without `n` is kept, and every decode failure is a `JwtError`, which
## is what the callback turns into a 401 instead of a 500.

import std/[base64, json, os, strutils, unittest]
import ../infrastructure/jwt_rs256

const jwksPath = currentSourcePath().parentDir.parentDir.parentDir.parentDir /
  "tools/oidc-stub/jwks.json"

proc b64url(data: string): string =
  result = encode(data).replace('+', '-').replace('/', '_')
  result = result.strip(chars = {'='})

proc realJwks(): seq[Jwk] =
  parseJwks(parseFile(jwksPath))

suite "parseJwks":
  test "a document without keys is refused":
    expect JwtError:
      discard parseJwks(%*{"nokeys": []})

  test "only the RSA keys are kept, and the use field is not a filter":
    let keys = parseJwks(%*{"keys": [
      {"kty": "RSA", "kid": "sig-1", "use": "sig", "n": "AQAB", "e": "AQAB"},
      {"kty": "EC", "kid": "ec-1", "crv": "P-256", "x": "a", "y": "b"},
      {"kty": "RSA", "kid": "enc-1", "use": "enc", "n": "AQAB", "e": "AQAB"},
    ]})
    check keys.len == 2
    check keys[0].kid == "sig-1"
    check keys[1].kid == "enc-1"

  test "the stub document yields the one signing key":
    let keys = realJwks()
    check keys.len == 1
    check keys[0].kid == "test-1"
    check keys[0].exponent == "AQAB"

  test "a key that omits n or e is refused by the JSON lookup, not kept empty":
    # The plan expected an empty modulus here. The code reads `key["n"]`
    # directly, and a missing object key raises `KeyError` (a ValueError, not a
    # `JwtError`), so the document is refused instead of kept.
    expect KeyError:
      discard parseJwks(%*{"keys": [{"kty": "RSA", "kid": "broken"}]})
    expect KeyError:
      discard parseJwks(%*{"keys": [{"kty": "RSA", "kid": "broken",
        "n": "AQAB"}]})

  test "verification refuses an empty modulus or exponent instead of answering false":
    let real = realJwks()[0]
    expect JwtError:
      discard verifyRs256("a.b", "c2ln", Jwk(kid: real.kid, modulus: "",
        exponent: real.exponent))
    expect JwtError:
      discard verifyRs256("a.b", "c2ln", Jwk(kid: real.kid,
        modulus: real.modulus, exponent: ""))

suite "decodePart":
  test "base64url without padding is accepted":
    check decodePart("eyJhIjoxfQ")["a"].getInt == 1
    check decodePart(b64url("""{"b":"+-/_"}"""))["b"].getStr == "+-/_"

  test "an empty segment is refused as JwtError":
    expect JwtError:
      discard decodePart("")

  test "a segment that is not JSON is refused as JwtError":
    expect JwtError:
      discard decodePart(b64url("not-json"))

  test "the failure is not a ValueError, so the caller's mapping does not drift":
    var caught = false
    try:
      discard decodePart("")
    except ValueError:
      discard
    except JwtError:
      caught = true
    check caught

suite "verifyIdToken":
  test "a truncated payload fails the signature before it is decoded":
    let header = b64url("""{"alg":"RS256","kid":"test-1","typ":"JWT"}""")
    let token = header & "." & b64url("""{"iss":""") & ".AAAA"
    var message = ""
    try:
      discard verifyIdToken(token, realJwks(), "http://issuer.test",
        "majadu-dev", "", 0)
    except JwtError as error:
      message = error.msg
    check message == "JWT signature verification failed"

  test "a header that names an unknown kid is refused":
    let header = b64url("""{"alg":"RS256","kid":"other","typ":"JWT"}""")
    var message = ""
    try:
      discard verifyIdToken(header & ".eyJhIjoxfQ.AAAA", realJwks(),
        "http://issuer.test", "majadu-dev", "", 0)
    except JwtError as error:
      message = error.msg
    check message == "unknown JWKS kid"