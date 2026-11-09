import std/[unittest]
import ../src/ratelimit

suite "rate limiter":
  test "allows up to the limit then asks to retry":
    let limiter = newLimiter()
    for _ in 0 ..< 3:
      check limiter.hit("/s/{code}|1.2.3.4", 3, 1000.0).allowed
    let blocked = limiter.hit("/s/{code}|1.2.3.4", 3, 1000.0)
    check not blocked.allowed
    check blocked.retryAfter >= 1

  test "the window resets after a minute":
    let limiter = newLimiter()
    discard limiter.hit("k", 1, 1000.0)
    check not limiter.hit("k", 1, 1030.0).allowed
    check limiter.hit("k", 1, 1061.0).allowed

  test "buckets are independent per route and client":
    let limiter = newLimiter()
    discard limiter.hit("/s/{code}|1.1.1.1", 1, 1000.0)
    check not limiter.hit("/s/{code}|1.1.1.1", 1, 1000.0).allowed
    check limiter.hit("/s/{code}|2.2.2.2", 1, 1000.0).allowed
    check limiter.hit("/c/{slug}/sessions|1.1.1.1", 1, 1000.0).allowed

  test "a zero limit disables the check":
    let limiter = newLimiter()
    for _ in 0 ..< 100:
      check limiter.hit("k", 0, 1000.0).allowed

  test "one address cannot mint more than its bucket cap":
    let limiter = newLimiter()
    for index in 0 ..< maxBucketsPerAddress + 8:
      discard limiter.hit("user:" & $index, 10, 1000.0, "203.0.113.7",
        evictable = true)
    check limiter.bucketCountFor("203.0.113.7") == maxBucketsPerAddress
    # Another address keeps its own allowance and is not evicted by the first.
    discard limiter.hit("user:elsewhere", 10, 1000.0, "203.0.113.8",
      evictable = true)
    check limiter.bucketCountFor("203.0.113.8") == 1
    check limiter.bucketCountFor("203.0.113.7") == maxBucketsPerAddress

  test "minted share buckets never evict the budget that enforces the limit":
    ## The reviewer's sequence: exhaust the address budget, then mint one
    ## share bucket per random code. The least recently seen bucket used to be
    ## the exhausted route bucket, so the next request started a fresh 300.
    let limiter = newLimiter()
    let address = "198.51.100.7"
    for _ in 0 ..< 300:
      check limiter.hit("route|/auth/start|" & address, 300, 1000.0,
        address).allowed
    check not limiter.hit("route|/auth/start|" & address, 300, 1000.0,
      address).allowed
    for index in 0 ..< maxBucketsPerAddress + 1:
      discard limiter.hit("share|code" & $index & "|" & address, 120,
        1001.0 + index.float, address, evictable = true)
    check not limiter.hit("route|/auth/start|" & address, 300, 1000.0,
      address).allowed

  test "a busy NAT keeps its address budget across many user buckets":
    ## A NAT of signed-in users adds a per-user bucket for every user. Those
    ## are pinned like the address budget, so the crowd cannot evict the
    ## anonymous budget and hand it a fresh window.
    let limiter = newLimiter()
    let address = "198.51.100.9"
    for _ in 0 ..< 300:
      discard limiter.hit("route|/healthz|" & address, 300, 1000.0, address)
    for index in 0 ..< 40:
      discard limiter.hit("route|/healthz|user:" & $index, 300,
        1001.0 + index.float, address)
    check not limiter.hit("route|/healthz|" & address, 300, 1000.0,
      address).allowed

  test "the global ceiling drops minted share buckets, never a pinned budget":
    ## The address-less per-code share bucket is minted for every distinct
    ## `/s/<code>`. Treating it as pinned let enough codes across a few
    ## addresses push the global sweep into evicting the address budget
    ## itself. Here the budget is exhausted, then more than maxBuckets
    ## per-code buckets are minted; the sweep must drop those instead.
    let limiter = newLimiter()
    let address = "198.51.100.21"
    for _ in 0 ..< 300:
      discard limiter.hit("route|/auth/start|" & address, 300, 1000.0, address)
    check not limiter.hit("route|/auth/start|" & address, 300, 1000.0,
      address).allowed
    var now = 1000.0
    var index = 0
    for _ in 0 ..< 10:
      for _ in 0 ..< 500:
        discard limiter.hit("share|code" & $index, 1200, now, "")
        inc index
      now += 5.0
    # One more hit at the next sweep tick brings the table back under the
    # ceiling. The exhausted budget must still be exhausted afterwards.
    discard limiter.hit("share|code" & $(index - 1), 1200, now, "")
    check limiter.bucketTotal() == maxBuckets
    check not limiter.hit("route|/auth/start|" & address, 300, now,
      address).allowed
