-- 0035: the audit retention predicate filters on occurred_at alone.
--
-- The two indexes from 0004 lead with community_id and actor_id, so
-- `where occurred_at < now() - interval` walked the whole append-only table.
-- This index is the one the purge needs; a monthly deletion that scans the
-- table is the one cost that grows forever.

create index if not exists audit_occurred_at_idx on account.audit (occurred_at);
