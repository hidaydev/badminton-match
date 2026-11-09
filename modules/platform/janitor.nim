import std/[json, times]
import db/db
import clock
import config/registry
import config/store

type
  PurgeOutcome* = object
    table*: string
    deleted*: int

const purgeTargets = [
  # Temporary rows only. Audit is deliberately absent: it has its own retention
  # and its own owner-run tool (see audit_retention.nim). A link is temporary
  # when it was revoked or when its own expiry has passed, even if nobody
  # revoked it: an expired row still sits in the one-live index.
  #
  # The third field says which cutoff the predicate binds: `false` is the
  # retention window, `true` is the clock itself. An OAuth flow is dead at
  # `expires_at`, not at `expires_at + retention`: `/auth/start` is
  # unauthenticated and writes one row per call, so keeping 30 days of rows
  # nobody can use only grows the table and slows the delete.
  ("auth.oauth_flows", "expires_at <= $1::timestamptz", true),
  ("platform.idempotency_keys", "expires_at < $1::timestamptz", false),
  ("platform.outbox",
   "processed_at is not null and processed_at < $1::timestamptz", false),
  ("session.links",
   "((revoked_at is not null and revoked_at < $1::timestamptz) or " &
     "(expires_at is not null and expires_at < $1::timestamptz))", false),
  ("account.sessions", "absolute_expires_at < $1::timestamptz", false),
  ("community.invite",
   "(accepted_at is not null or " &
     "(expires_at is not null and expires_at < $1::timestamptz))", false),
  ("platform.ops_token",
   "expires_at is not null and expires_at < $1::timestamptz and " &
     "revoked_at is not null", false),
  ("platform.ws_ticket", "expires_at < $1::timestamptz", false),
]

proc purge*(db: Db, retentionDays: int): seq[PurgeOutcome] =
  ## Deletes rows older than the configured window, and rows that are dead at
  ## their own expiry. The cutoff comes from the application clock, so a test
  ## that pins `MAJADU_NOW` controls the window and does not have to write
  ## `now() - interval` into its fixtures.
  let nowCut = utcNow()
  let cut = nowCut - initDuration(days = retentionDays)
  let cutText = cut.format("yyyy-MM-dd'T'HH:mm:ss'Z'")
  let nowText = nowCut.format("yyyy-MM-dd'T'HH:mm:ss'Z'")
  for (table, predicate, atExpiry) in purgeTargets:
    let deleted = db.execUpdate(
      "delete from " & table & " where " & predicate,
      @[textParam(if atExpiry: nowText else: cutText)])
    result.add(PurgeOutcome(table: table, deleted: deleted))

proc purgeWithConfig*(db: Db, snapshot: Snapshot): seq[PurgeOutcome] =
  purge(db, snapshot.intValue(%*{}, keyJanitorRetentionDays))
