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
  # and its own owner-run tool (see audit_retention.nim).
  ("auth.oauth_flows", "expires_at < cut"),
  ("platform.idempotency_keys", "expires_at < cut"),
  ("platform.outbox", "processed_at is not null and processed_at < cut"),
  ("session.links", "revoked_at is not null and revoked_at < cut"),
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
