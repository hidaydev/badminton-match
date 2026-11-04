import std/[locks, tables]

type
  Bucket* = object
    windowStart*: float
    count*: int

  Limiter* = ref object
    ## Fixed-window counters in process memory. The window is one minute, which
    ## is the granularity of every configured limit; a distributed deployment
    ## would move this table to shared storage, and the API would not change.
    lock: Lock
    buckets: Table[string, Bucket]

  Decision* = object
    allowed*: bool
    retryAfter*: int

const windowSeconds = 60.0

proc newLimiter*(): Limiter =
  result = Limiter()
  initLock(result.lock)
  result.buckets = initTable[string, Bucket]()

proc bucketKey(routeTemplate, clientIp: string): string =
  routeTemplate & "|" & clientIp

proc hit*(limiter: Limiter, key: string, limit: int, now: float): Decision =
  ## Returns the remaining allowance decision for one request. A limit of zero
  ## disables the check for that key.
  if limit <= 0:
    return Decision(allowed: true, retryAfter: 0)
  acquire(limiter.lock)
  try:
    var bucket = limiter.buckets.getOrDefault(key)
    if bucket.windowStart == 0 or now - bucket.windowStart >= windowSeconds:
      bucket = Bucket(windowStart: now, count: 0)
    if bucket.count >= limit:
      let elapsed = now - bucket.windowStart
      let retry = max(1, int(windowSeconds - elapsed) + 1)
      limiter.buckets[key] = bucket
      return Decision(allowed: false, retryAfter: retry)
    bucket.count.inc
    limiter.buckets[key] = bucket
    Decision(allowed: true, retryAfter: 0)
  finally:
    release(limiter.lock)

proc reset*(limiter: Limiter) =
  acquire(limiter.lock)
  limiter.buckets.clear()
  release(limiter.lock)
