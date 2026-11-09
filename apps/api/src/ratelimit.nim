import std/[algorithm, locks, tables]

type
  Bucket* = object
    windowStart*: float
    count*: int
    lastSeen*: float
    address*: string
    ## Only a bucket whose key the caller can mint at will (a share-code
    ## viewer bucket) may be evicted to make room for another key from the
    ## same address. The buckets that enforce a limit -- the address route
    ## budget, the identity pre-limit and every per-user budget -- are pinned,
    ## so minting keys can never reset the budget the address is charged on.
    evictable*: bool

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
  ## A single address may hold at most this many buckets. Session identities
  ## are the only keys a client can mint, so this bounds cookie rotation even
  ## before the global sweep runs.
  maxBucketsPerAddress* = 16
  sweepIntervalSeconds = 5.0

proc newLimiter*(): Limiter =
  result = Limiter()
  initLock(result.lock)
  result.buckets = initTable[string, Bucket]()

proc sweep(limiter: Limiter, now: float) =
  ## Drops finished windows first, then the least recently used mintable
  ## entries. Called with the lock held. Pinned buckets are only evicted when
  ## the table is over the hard ceiling and no mintable entry is left, which
  ## keeps memory bounded without letting key churn reset a live budget.
  var expired: seq[string] = @[]
  for key, bucket in limiter.buckets:
    if now - bucket.windowStart >= windowSeconds:
      expired.add(key)
  for key in expired:
    limiter.buckets.del(key)
  if limiter.buckets.len <= maxBuckets:
    return
  var evictable = newSeqOfCap[(float, string)](limiter.buckets.len)
  var pinned = newSeqOfCap[(float, string)](limiter.buckets.len)
  for key, bucket in limiter.buckets:
    if bucket.evictable:
      evictable.add((bucket.lastSeen, key))
    else:
      pinned.add((bucket.lastSeen, key))
  evictable.sort()
  pinned.sort()
  var excess = limiter.buckets.len - maxBuckets
  for candidate in evictable:
    if excess <= 0:
      break
    limiter.buckets.del(candidate[1])
    dec excess
  for candidate in pinned:
    if excess <= 0:
      break
    limiter.buckets.del(candidate[1])
    dec excess

proc evictForAddress(limiter: Limiter, address: string) =
  ## Called with the lock held when a new mintable key would push this address
  ## past its cap. Only another mintable bucket of that address is a candidate:
  ## the bucket that enforces the limit is pinned, so minting share codes can
  ## never hand the address a fresh budget. One client cannot evict another
  ## address's buckets.
  var victim = ""
  var oldest = 0.0
  var owned = 0
  for key, bucket in limiter.buckets:
    if bucket.address != address or not bucket.evictable:
      continue
    inc owned
    if victim.len == 0 or bucket.lastSeen < oldest:
      victim = key
      oldest = bucket.lastSeen
  if owned >= maxBucketsPerAddress and victim.len > 0:
    limiter.buckets.del(victim)

proc bucketCountFor*(limiter: Limiter, address: string): int =
  ## How many buckets one address currently owns. The regression test for the
  ## per-address cap reads this instead of guessing from the global table.
  acquire(limiter.lock)
  try:
    for _, bucket in limiter.buckets:
      if bucket.address == address:
        inc result
  finally:
    release(limiter.lock)

proc hit*(limiter: Limiter, key: string, limit: int, now: float,
          address = "", evictable = false): Decision =
  ## Returns the remaining allowance decision for one request. A limit of zero
  ## disables the check for that key. `address` ties a key to the client that
  ## asked for it, which is what bounds the table per client; `evictable` is
  ## only true for a key that same client can mint, so the default protects the
  ## budget that enforces the limit.
  if limit <= 0:
    return Decision(allowed: true, retryAfter: 0)
  acquire(limiter.lock)
  try:
    if now >= limiter.nextSweep:
      limiter.sweep(now)
      limiter.nextSweep = now + sweepIntervalSeconds
    let known = limiter.buckets.hasKey(key)
    if not known and address.len > 0 and evictable:
      limiter.evictForAddress(address)
    var bucket = limiter.buckets.getOrDefault(key)
    if bucket.windowStart == 0 or now - bucket.windowStart >= windowSeconds:
      bucket = Bucket(windowStart: now, count: 0)
    bucket.address = address
    bucket.evictable = bucket.evictable or evictable
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