import std/[json, strutils, times]
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
  ("auth.oauth_flows", "expires_at < cut"),
  ("platform.idempotency_keys", "expires_at < cut"),
  ("platform.outbox", "processed_at is not null and processed_at < cut"),
  ("session.links",
   "((revoked_at is not null and revoked_at < cut) or " &
     "(expires_at is not null and expires_at < cut))"),
  ("account.sessions", "absolute_expires_at < cut"),
  ("community.invite",
   "(accepted_at is not null or (expires_at is not null and expires_at < cut))"),
  ("platform.ops_token",
   "expires_at is not null and expires_at < cut and revoked_at is not null"),
  ("platform.ws_ticket", "expires_at < cut"),
]

proc purge*(db: Db, retentionDays: int): seq[PurgeOutcome] =
  ## Deletes rows older than the configured window. The cutoff comes from the
  ## application clock, so a test that pins `MAJADU_NOW` controls the window and
  ## does not have to write `now() - interval` into its fixtures.
  let cut = utcNow() - initDuration(days = retentionDays)
  let cutText = cut.format("yyyy-MM-dd'T'HH:mm:ss'Z'")
  for (table, predicate) in purgeTargets:
    let deleted = db.execUpdate(
      "delete from " & table & " where " &
        predicate.replace("cut", "$1::timestamptz"),
      @[textParam(cutText)])
    result.add(PurgeOutcome(table: table, deleted: deleted))

proc purgeWithConfig*(db: Db, snapshot: Snapshot): seq[PurgeOutcome] =
  purge(db, snapshot.intValue(%*{}, keyJanitorRetentionDays))
