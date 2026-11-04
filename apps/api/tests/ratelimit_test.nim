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
