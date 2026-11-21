-- 0057: the two janitor deletes that still scanned their table.
--
-- `modules/platform/janitor.nim` deletes processed outbox rows and revoked
-- links. Neither predicate had an index:
--
--   * `platform.outbox` only carried `outbox_pending_idx on (created_at) where
--     processed_at is null` (0004), which covers the exact opposite half of the
--     rows the purge targets. An outbox only grows, so the nightly delete read
--     the whole table.
--   * `session.links` had no index on `revoked_at` at all, and 0043's
--     `links_expiry_idx` is partial on `revoked_at is null`, so the revoke
--     branch could not use it either.
--
-- The purge is split into one DELETE per branch (the pair of partial indexes
-- below matches one branch each) instead of one `or` that no index can serve.
--
-- Plain, not `concurrently`: dbtools applies every pending file inside one
-- transaction, so `create index concurrently` cannot run here (same reason as
-- 0031). The build takes a SHARE lock on each table for its duration; neither
-- is large enough to matter in a maintenance window, and the archive import
-- that would make them large runs before these indexes exist.
--
-- Down path: drop both indexes, nothing else depends on them.
--   drop index if exists platform.outbox_processed_idx;
--   drop index if exists session.links_revoked_idx;
-- The janitor keeps working without them and scans those two branches again.

create index if not exists outbox_processed_idx
  on platform.outbox (processed_at)
  where processed_at is not null;

create index if not exists links_revoked_idx
  on session.links (revoked_at)
  where revoked_at is not null;
