import std/[json, strutils]
import db/db
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
  ## Deletes rows older than the configured window. The cutoff is computed by
  ## the database so every table uses the same clock.
  for (table, predicate) in purgeTargets:
    let deleted = db.execUpdate(
      "delete from " & table & " where " & predicate.replace("cut",
        "(now() - make_interval(days => $1))"),
      @[intParam(retentionDays.int64)])
    result.add(PurgeOutcome(table: table, deleted: deleted))

proc purgeWithConfig*(db: Db, snapshot: Snapshot): seq[PurgeOutcome] =
  purge(db, snapshot.intValue(%*{}, keyJanitorRetentionDays))
