import std/[json, times]
import db/db
import clock
import config/registry
import config/store

type
  PurgeOutcome* = object
    table*: string
    deleted*: int

  PurgeCutoff = enum
    ## Which instant a branch binds to `$1`.
    cutoffWindow  ## the retention window: `now - retentionDays`
    cutoffExpiry  ## the clock itself: the row is dead at its own expiry
    cutoffNone    ## every row the predicate names is dead; it binds nothing

  PurgeTarget = tuple
    ## One delete branch. `tenanted` is true for a table carrying
    ## `community_id`: those are swept per community through a scoped facade,
    ## because a statement that names no community matches nothing once the
    ## policy set is on, and a nightly job that deletes zero rows is a silent
    ## failure.
    table: string
    predicate: string
    cutoff: PurgeCutoff
    tenanted: bool

const purgeTargets: array[10, PurgeTarget] = [
  # Temporary rows only. Audit is deliberately absent: it has its own retention
  # and its own owner-run tool (see audit_retention.nim). A link is temporary
  # when it was revoked or when its own expiry has passed, even if nobody
  # revoked it: an expired row still sits in the one-live index.
  #
  # A branch binds the cutoff it names: `cutoffExpiry` is the clock itself,
  # because an OAuth flow is dead at `expires_at`, not at `expires_at +
  # retention`. `/auth/start` is unauthenticated and writes one row per call, so
  # keeping 30 days of rows nobody can use only grows the table and slows the
  # delete.
  #
  # One entry per branch, never one predicate with an `or`: a partial index is
  # matched by a single branch, and an `or` over two of them is a predicate the
  # planner can only answer with a scan (0043, 0057).
  ("auth.oauth_flows", "expires_at <= $1::timestamptz", cutoffExpiry, false),
  ("platform.idempotency_keys", "expires_at < $1::timestamptz", cutoffWindow,
   false),
  ("platform.outbox",
   "processed_at is not null and processed_at < $1::timestamptz", cutoffWindow,
   false),
  ("session.links",
   "revoked_at is not null and revoked_at < $1::timestamptz", cutoffWindow,
   true),
  # `revoked_at is null` is repeated so this branch matches `links_expiry_idx`
  # exactly. A link that is both revoked and expired therefore goes when the
  # revocation ages out, which is the window a revoked link gets anyway.
  ("session.links",
   "revoked_at is null and expires_at is not null and " &
     "expires_at < $1::timestamptz", cutoffWindow, true),
  ("account.sessions", "absolute_expires_at < $1::timestamptz", cutoffWindow,
   false),
  # An accepted invite is dead whatever its age, so that branch binds no cutoff;
  # the expired one repeats `accepted_at is null` to match `invite_expiry_idx`.
  ("community.invite", "accepted_at is not null", cutoffNone, true),
  ("community.invite",
   "accepted_at is null and expires_at is not null and " &
     "expires_at < $1::timestamptz", cutoffWindow, true),
  ("platform.ops_token",
   "expires_at is not null and expires_at < $1::timestamptz and " &
     "revoked_at is not null", cutoffWindow, false),
  ("platform.ws_ticket", "expires_at < $1::timestamptz", cutoffWindow, false),
]

const janitorPurgeBatch* = 10000
  ## Rows per statement. The audit cleaner uses the same bound for the same
  ## reason: one DELETE over a whole backlog is one long transaction, one WAL
  ## burst and one dead-tuple mountain for autovacuum. Each batch is its own
  ## transaction, so a backlog larger than one batch is finished by the next
  ## run; the predicate is time-based, so nothing is lost by splitting it.

proc purgeBatch(db: Db, table, predicate: string, params: seq[DbParam],
                batchSize: int): int =
  ## Deletes the matching rows in bounded statements. `ctid in (select ctid …
  ## limit n)` is the shape `audit_retention.nim` uses: the subquery is what the
  ## partial index serves, and the bound is what keeps one statement short.
  let limitRef = if params.len == 0: "$1" else: "$2"
  var total = 0
  while true:
    var bound = params
    bound.add(intParam(batchSize.int64))
    let deleted = db.execUpdate(
      "delete from " & table & " where ctid in (" &
        "select ctid from " & table & " where " & predicate &
        " limit " & limitRef & ")",
      bound)
    total += deleted
    if deleted < batchSize:
      return total

proc purgeTenanted(db: Db, targets: seq[PurgeTarget], cutText, nowText: string,
                   batchSize: int): seq[PurgeOutcome] =
  ## The tenant branches, swept once per community. `platform.community` carries
  ## no policy, so reading it needs no context; every delete after it is issued
  ## through a facade that declares one community. Without the loop a nightly
  ## run would match zero rows and still exit 0, which is the failure this
  ## release exists to prevent.
  for row in db.query("select id from platform.community order by slug"):
    let communityId = row.get("id")
    let scopedDb = db.scoped(communityId)
    for target in targets:
      var params: seq[DbParam] = @[]
      case target.cutoff
      of cutoffWindow: params.add(textParam(cutText))
      of cutoffExpiry: params.add(textParam(nowText))
      of cutoffNone: discard
      let deleted = purgeBatch(scopedDb, target.table, target.predicate, params,
        batchSize)
      var merged = false
      for outcome in result.mitems:
        if outcome.table == target.table:
          outcome.deleted += deleted
          merged = true
          break
      if not merged:
        result.add(PurgeOutcome(table: target.table, deleted: deleted))

proc purgePlatform(db: Db, targets: seq[PurgeTarget], cutText, nowText: string,
                   batchSize: int): seq[PurgeOutcome] =
  ## The branches whose tables carry no `community_id`: one pass on the plain
  ## pool, because there is no tenant to declare and no policy to satisfy.
  for target in targets:
    var params: seq[DbParam] = @[]
    case target.cutoff
    of cutoffWindow: params.add(textParam(cutText))
    of cutoffExpiry: params.add(textParam(nowText))
    of cutoffNone: discard
    let deleted = purgeBatch(db, target.table, target.predicate, params,
      batchSize)
    var merged = false
    for outcome in result.mitems:
      if outcome.table == target.table:
        outcome.deleted += deleted
        merged = true
        break
    if not merged:
      result.add(PurgeOutcome(table: target.table, deleted: deleted))

proc purge*(db: Db, retentionDays: int,
            batchSize = janitorPurgeBatch): seq[PurgeOutcome] =
  ## Deletes rows older than the configured window, and rows that are dead at
  ## their own expiry. The cutoff comes from the application clock, so a test
  ## that pins `MAJADU_NOW` controls the window and does not have to write
  ## `now() - interval` into its fixtures.
  if batchSize < 1:
    raise newException(ValueError, "batchSize must be positive")
  let nowCut = utcNow()
  let cut = nowCut - initDuration(days = retentionDays)
  let cutText = cut.format("yyyy-MM-dd'T'HH:mm:ss'Z'")
  let nowText = nowCut.format("yyyy-MM-dd'T'HH:mm:ss'Z'")
  var tenanted: seq[PurgeTarget] = @[]
  var platform: seq[PurgeTarget] = @[]
  for target in purgeTargets:
    if target.tenanted: tenanted.add(target) else: platform.add(target)
  # Tenant tables first, one community at a time, then the platform tables once
  # on the plain pool. Both passes keep `withPinnedClock` behaviour: the cutoff
  # is computed once, so the community loop cannot straddle a clock tick.
  result = purgeTenanted(db, tenanted, cutText, nowText, batchSize)
  for outcome in purgePlatform(db, platform, cutText, nowText, batchSize):
    var merged = false
    for existing in result.mitems:
      if existing.table == outcome.table:
        existing.deleted += outcome.deleted
        merged = true
        break
    if not merged:
      result.add(outcome)

proc purgeWithConfig*(db: Db, snapshot: Snapshot): seq[PurgeOutcome] =
  purge(db, snapshot.intValue(%*{}, keyJanitorRetentionDays))
