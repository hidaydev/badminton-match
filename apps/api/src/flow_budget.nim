import std/[locks, tables]

## `POST /auth/start` is unauthenticated and writes one `auth.oauth_flows` row
## per request, so a scripted minute can add hundreds of pending flows (QAE-05).
## The row carries no address, and the address is what the budget is charged
## on, so the count of pending rows an address owns lives here instead: this
## process is the only writer of those rows (BE-23 records the single-instance
## decision), and an entry leaves the table when the flow is consumed or when
## it expires, which is exactly what "pending" means.
##
## A row written by an earlier process cannot be counted, so a restart starts
## every address at zero; the cap still bounds what one address can add between
## restarts, and the janitor reclaims the rows by `expires_at`.

type
  FlowEntry = object
    address: string
    expires: float

  FlowBudget* = ref object
    lock: Lock
    flows: Table[string, FlowEntry]
      ## State hash to the address that started it and the row's expiry.

const
  ## Hard ceiling on the table, mirroring the limiter's bound: an address is
  ## capped, but a client that rotates addresses must not grow this table
  ## without limit. Reaching it evicts the entry closest to expiry.
  maxEntries* = 4096

proc newFlowBudget*(): FlowBudget =
  result = FlowBudget()
  initLock(result.lock)
  result.flows = initTable[string, FlowEntry]()

proc prune(budget: FlowBudget, now: float) =
  ## Called with the lock held. An expired row is gone from the database too
  ## (the janitor or the callback deletes it), so its slot is free.
  var expired: seq[string] = @[]
  for key, entry in budget.flows:
    if entry.expires <= now:
      expired.add(key)
  for key in expired:
    budget.flows.del(key)

proc evictEarliest(budget: FlowBudget) =
  ## Called with the lock held and the table at its ceiling: the flow that is
  ## closest to expiring is the one that frees a slot soonest anyway.
  var victim = ""
  var earliest = 0.0
  for key, entry in budget.flows:
    if victim.len == 0 or entry.expires < earliest:
      victim = key
      earliest = entry.expires
  if victim.len > 0:
    budget.flows.del(victim)

proc pendingFor*(budget: FlowBudget, address: string, now: float): int =
  ## Pending flows one address owns right now. A regression test reads this
  ## instead of guessing from the table.
  acquire(budget.lock)
  try:
    budget.prune(now)
    for _, entry in budget.flows:
      if entry.address == address:
        inc result
  finally:
    release(budget.lock)

proc admit*(budget: FlowBudget, state, address: string, expires, now: float,
            cap: int): int =
  ## `0` means the row may be written and the slot is reserved. A positive
  ## value is the number of seconds until one of the address's pending flows
  ## expires, which is the `Retry-After` a refused caller is given.
  acquire(budget.lock)
  try:
    budget.prune(now)
    var held = 0
    var earliest = 0.0
    for _, entry in budget.flows:
      if entry.address != address:
        continue
      inc held
      if earliest == 0.0 or entry.expires < earliest:
        earliest = entry.expires
    if held >= cap:
      return max(1, int(earliest - now) + 1)
    if budget.flows.len >= maxEntries:
      budget.evictEarliest()
    budget.flows[state] = FlowEntry(address: address, expires: expires)
    0
  finally:
    release(budget.lock)

proc release*(budget: FlowBudget, state: string) =
  ## The callback deleted the row whether the rest of the login succeeds or
  ## not, so the slot is free either way.
  acquire(budget.lock)
  try:
    budget.flows.del(state)
  finally:
    release(budget.lock)

proc reset*(budget: FlowBudget) =
  acquire(budget.lock)
  budget.flows.clear()
  release(budget.lock)
