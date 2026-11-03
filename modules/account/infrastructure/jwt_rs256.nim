import std/[base64, json, strutils]

when defined(macosx):
  const cryptoLib = "libcrypto.3.dylib"
else:
  const cryptoLib = "libcrypto.so.3"

type
  JwtError* = object of CatchableError
  Jwk* = object
    kid*: string
    modulus*: string
    exponent*: string

proc EVP_MD_CTX_new(): pointer {.cdecl, dynlib: cryptoLib, importc.}
proc EVP_MD_CTX_free(ctx: pointer) {.cdecl, dynlib: cryptoLib, importc.}
proc EVP_sha256(): pointer {.cdecl, dynlib: cryptoLib, importc.}
proc EVP_DigestVerifyInit(ctx, pctx, md, engine, pkey: pointer): cint
  {.cdecl, dynlib: cryptoLib, importc.}
proc EVP_DigestVerifyUpdate(ctx: pointer, data: pointer, length: csize_t): cint
  {.cdecl, dynlib: cryptoLib, importc.}
proc EVP_DigestVerifyFinal(ctx: pointer, signature: pointer, length: csize_t): cint
  {.cdecl, dynlib: cryptoLib, importc.}
proc EVP_PKEY_new(): pointer {.cdecl, dynlib: cryptoLib, importc.}
proc EVP_PKEY_free(key: pointer) {.cdecl, dynlib: cryptoLib, importc.}
proc EVP_PKEY_assign(key: pointer, keyType: cint, value: pointer): cint
  {.cdecl, dynlib: cryptoLib, importc.}
proc RSA_new(): pointer {.cdecl, dynlib: cryptoLib, importc.}
proc RSA_free(rsa: pointer) {.cdecl, dynlib: cryptoLib, importc.}
proc BN_bin2bn(data: pointer, length: cint, ret: pointer): pointer
  {.cdecl, dynlib: cryptoLib, importc.}
proc BN_free(number: pointer) {.cdecl, dynlib: cryptoLib, importc.}
proc RSA_set0_key(rsa, n, e, d: pointer): cint
  {.cdecl, dynlib: cryptoLib, importc.}

const rsaType = 6.cint

proc b64urlDecode(value: string): string =
  var padded = value.replace('-', '+').replace('_', '/')
  while padded.len mod 4 != 0:
    padded.add('=')
  decode(padded)

proc toBigNumber(value: string): pointer =
  let bytes = b64urlDecode(value)
  if bytes.len == 0:
    raise newException(JwtError, "empty JWK integer")
  let number = BN_bin2bn(unsafeAddr bytes[0], bytes.len.cint, nil)
  if number == nil:
    raise newException(JwtError, "cannot allocate bignum")
  number

proc publicKey(jwk: Jwk): pointer =
  let rsa = RSA_new()
  if rsa == nil:
    raise newException(JwtError, "cannot allocate RSA")
  let n = toBigNumber(jwk.modulus)
  let e = toBigNumber(jwk.exponent)
  if RSA_set0_key(rsa, n, e, nil) != 1:
    BN_free(n)
    BN_free(e)
    RSA_free(rsa)
    raise newException(JwtError, "cannot set RSA key")
  let pkey = EVP_PKEY_new()
  if pkey == nil or EVP_PKEY_assign(pkey, rsaType, rsa) != 1:
    RSA_free(rsa)
    if pkey != nil:
      EVP_PKEY_free(pkey)
    raise newException(JwtError, "cannot wrap RSA key")
  pkey

proc verifyRs256*(signingInput, signature: string, jwk: Jwk): bool =
  let key = publicKey(jwk)
  defer: EVP_PKEY_free(key)
  let ctx = EVP_MD_CTX_new()
  if ctx == nil:
    raise newException(JwtError, "cannot allocate digest context")
  defer: EVP_MD_CTX_free(ctx)
  if EVP_DigestVerifyInit(ctx, nil, EVP_sha256(), nil, key) != 1:
    raise newException(JwtError, "EVP_DigestVerifyInit failed")
  if signingInput.len > 0:
    let data = signingInput.cstring
    if EVP_DigestVerifyUpdate(ctx, cast[pointer](data), signingInput.len.csize_t) != 1:
      raise newException(JwtError, "EVP_DigestVerifyUpdate failed")
  let sig = if signature.len == 0: nil else: cast[pointer](unsafeAddr signature[0])
  EVP_DigestVerifyFinal(ctx, sig, signature.len.csize_t) == 1

proc parseJwks*(document: JsonNode): seq[Jwk] =
  if not document.hasKey("keys"):
    raise newException(JwtError, "JWKS has no keys")
  for key in document["keys"]:
    if key["kty"].getStr() != "RSA":
      continue
    result.add(Jwk(
      kid: key["kid"].getStr(),
      modulus: key["n"].getStr(),
      exponent: key["e"].getStr(),
    ))

proc decodePart*(value: string): JsonNode =
  try:
    parseJson(b64urlDecode(value))
  except CatchableError:
    raise newException(JwtError, "invalid JWT segment")

proc verifyIdToken*(token: string, jwks: seq[Jwk], issuer, audience,
                    nonce: string, nowUnix: int64): JsonNode =
  let parts = token.split('.')
  if parts.len != 3:
    raise newException(JwtError, "JWT must have three segments")
  let header = decodePart(parts[0])
  if header["alg"].getStr() != "RS256":
    raise newException(JwtError, "unexpected JWT algorithm")
  let kid = header["kid"].getStr()
  var key: Jwk
  var found = false
  for candidate in jwks:
    if candidate.kid == kid:
      key = candidate
      found = true
  if not found:
    raise newException(JwtError, "unknown JWKS kid")
  if not verifyRs256(parts[0] & "." & parts[1], b64urlDecode(parts[2]), key):
    raise newException(JwtError, "JWT signature verification failed")
  let claims = decodePart(parts[1])
  if claims["iss"].getStr() != issuer:
    raise newException(JwtError, "unexpected issuer")
  if claims["aud"].getStr() != audience:
    raise newException(JwtError, "unexpected audience")
  if claims["exp"].getInt() <= nowUnix:
    raise newException(JwtError, "JWT expired")
  if nonce.len > 0 and claims["nonce"].getStr() != nonce:
    raise newException(JwtError, "nonce mismatch")
  claims
