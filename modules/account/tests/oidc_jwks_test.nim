## BE-05: the JWKS cache owns one lock initialised at module load, fetches
## outside it, and refreshes once when a token names a key id the snapshot does
## not hold. These cases replace the network fetch with a pure function.
import std/[atomics, base64, json, strutils, unittest]
import ../infrastructure/oidc
import ../infrastructure/jwt_rs256

var fetchCount {.global.}: Atomic[int]

proc fakeFetcher(config: OidcConfig): seq[Jwk] =
  discard fetchCount.fetchAdd(1, moRelaxed)
  @[Jwk(kid: "k2", modulus: "AQAB", exponent: "AQAB")]

proc b64url(value: string): string =
  result = encode(value).replace('+', '-').replace('/', '_')
  result = result.strip(chars = {'='})

proc tokenWithKid(kid: string): string =
  let header = %*{"alg": "RS256", "kid": kid}
  let payload = %*{
    "sub": "subject", "iss": "issuer", "aud": "client",
    "exp": 9999999999, "nonce": "n", "email": "person@example.com",
    "email_verified": true,
  }
  b64url($header) & "." & b64url($payload) & ".c2ln"

type
  WorkerArgs = object
    config: OidcConfig

proc firstLogin(args: WorkerArgs) {.thread.} =
  {.cast(gcsafe).}:
    discard jwks(args.config)

suite "JWKS cache":
  setup:
    fetchCount.store(0, moRelaxed)
    setJwksFetcher(fakeFetcher)
    resetJwksCache()
  teardown:
    resetJwksCache()

  test "an unknown key id refreshes exactly once":
    let config = OidcConfig(jwksUrl: "http://provider.test/jwks")
    discard jwks(config)
    fetchCount.store(0, moRelaxed)
    var rejected = false
    try:
      discard verifyIdTokenWithRefresh(config, tokenWithKid("k9"),
        "issuer", "client", "n", 0)
    except JwtError:
      rejected = true
    check rejected
    # One forced fetch, then the retry is rejected instead of looping.
    check fetchCount.load(moRelaxed) == 1

  test "a known key id never refetches":
    let config = OidcConfig(jwksUrl: "http://provider.test/jwks")
    discard jwks(config)
    fetchCount.store(0, moRelaxed)
    try:
      discard verifyIdTokenWithRefresh(config, tokenWithKid("k2"),
        "issuer", "client", "n", 0)
    except JwtError:
      discard
    check fetchCount.load(moRelaxed) == 0

  test "the retry after a refetch checks the signature, not the key id":
    ## SEC-17: a rotation is routine, not adversarial. The first attempt misses
    ## the id, the forced refetch brings it, and the retry reaches the signature
    ## check, which is the only thing left for a real provider token.
    var calls = 0
    setJwksFetcher(proc(config: OidcConfig): seq[Jwk] =
      inc calls
      if calls == 1: @[]
      else: @[Jwk(kid: "k9", modulus: "AQAB", exponent: "AQAB")])
    let config = OidcConfig(jwksUrl: "http://provider.test/jwks")
    var message = ""
    try:
      discard verifyIdTokenWithRefresh(config, tokenWithKid("k9"), "issuer",
        "client", "n", 0)
    except JwtError as error:
      message = error.msg
    check calls == 2
    check message != "unknown JWKS kid"
    check message.len > 0

  test "eight concurrent first logins initialise the cache without a race":
    # The lock is initialised at module load, so there is no `initLock` on the
    # request path for two threads to enter. The stress is what proves it.
    let config = OidcConfig(jwksUrl: "http://provider.test/jwks")
    var threads: array[8, Thread[WorkerArgs]]
    for index in 0 ..< threads.len:
      createThread(threads[index], firstLogin, WorkerArgs(config: config))
    for index in 0 ..< threads.len:
      joinThread(threads[index])
    check fetchCount.load(moRelaxed) >= 1
    # The snapshot is populated, so a later call reuses it instead of fetching.
    let before = fetchCount.load(moRelaxed)
    discard jwks(config)
    check fetchCount.load(moRelaxed) == before

  test "a failed refresh serves the previous key set instead of raising":
    # SQ-08: an identity-provider blip used to turn every login into a fresh
    # round trip to a host that was already failing.
    var attempts = 0
    var failing = false
    setJwksFetcher(proc(config: OidcConfig): seq[Jwk] =
      inc attempts
      if failing:
        raise newException(ValueError, "provider is down")
      @[Jwk(kid: "k1", modulus: "AQAB", exponent: "AQAB")])
    let config = OidcConfig(jwksUrl: "http://provider.test/jwks")
    check jwks(config).len == 1
    check attempts == 1
    # Age the entry past its TTL without waiting the hour: the next call takes
    # the refresh path against a provider that is now down.
    expireJwksCache()
    failing = true
    check jwks(config).len == 1
    check attempts == 2
    # Inside the retry window the provider is not asked again, and the stale
    # keys are still served.
    for _ in 0 ..< 5:
      check jwks(config).len == 1
    check attempts == 2

  test "a refresh failure with no keys in hand still raises":
    var attempts = 0
    setJwksFetcher(proc(config: OidcConfig): seq[Jwk] =
      inc attempts
      raise newException(ValueError, "provider is down"))
    let config = OidcConfig(jwksUrl: "http://provider.test/jwks")
    var raised = false
    try:
      discard jwks(config)
    except ValueError:
      raised = true
    check raised
    check attempts == 1
    # The retry window applies to the empty cache too, so a second login does
    # not reach the network while the provider is known to be down.
    check jwks(config).len == 0
    check attempts == 1
