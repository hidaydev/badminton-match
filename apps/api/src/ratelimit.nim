import std/[algorithm, locks, tables]

type
  Bucket* = object
    windowStart*: float
    count*: int
    lastSeen*: float

  Limiter* = ref object
    ## Fixed-window counters in process memory. The window is one minute, which
    ## is the granularity of every configured limit; a distributed deployment
    ## would move this table to shared storage, and the API would not change.
    lock: Lock
    buckets: Table[string, Bucket]
    nextSweep: float

  Decision* = object
    allowed*: bool
    retryAfter*: int

const
  windowSeconds = 60.0
  ## Hard ceiling on the table. An anonymous client can mint a key per path it
  ## invents, so the table is swept and bounded instead of growing forever.
  maxBuckets = 4096
  sweepIntervalSeconds = 5.0

proc newLimiter*(): Limiter =
  result = Limiter()
  initLock(result.lock)
  result.buckets = initTable[string, Bucket]()

proc sweep(limiter: Limiter, now: float) =
  ## Drops finished windows first, then the least recently used entries. Called
  ## with the lock held.
  var expired: seq[string] = @[]
  for key, bucket in limiter.buckets:
    if now - bucket.windowStart >= windowSeconds:
      expired.add(key)
  for key in expired:
    limiter.buckets.del(key)
  if limiter.buckets.len <= maxBuckets:
    return
  var keys = newSeqOfCap[(float, string)](limiter.buckets.len)
  for key, bucket in limiter.buckets:
    keys.add((bucket.lastSeen, key))
  keys.sort()
  let excess = limiter.buckets.len - maxBuckets
  for index in 0 ..< excess:
    limiter.buckets.del(keys[index][1])

proc hit*(limiter: Limiter, key: string, limit: int, now: float): Decision =
  ## Returns the remaining allowance decision for one request. A limit of zero
  ## disables the check for that key.
  if limit <= 0:
    return Decision(allowed: true, retryAfter: 0)
  acquire(limiter.lock)
  try:
    if now >= limiter.nextSweep:
      limiter.sweep(now)
      limiter.nextSweep = now + sweepIntervalSeconds
    var bucket = limiter.buckets.getOrDefault(key)
    if bucket.windowStart == 0 or now - bucket.windowStart >= windowSeconds:
      bucket = Bucket(windowStart: now, count: 0)
    bucket.lastSeen = now
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
  limiter.nextSweep = 0
  release(limiter.lock)