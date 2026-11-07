-- 0031: pending invitations are looked up by address on every login.
--
-- `acceptPendingForEmail` claims invites with `where email_hash = $1 and
-- accepted_at is null and (expires_at is null or expires_at > now())` from the
-- OIDC callback, so a login without an index reads the whole invite table and
-- takes a row lock on each match. Rows are never deleted, so the table only
-- grows; accepted ones are dead weight for this query.
--
-- The index is partial on `accepted_at is null`, which is the half of the
-- predicate that can be indexed. `now()` is not immutable, so the `expires_at`
-- branch cannot appear in an index predicate and stays a filter on the rows the
-- index returns.
--
-- Not `concurrently`: dbtools applies every pending file inside one transaction
-- (tools/dbtools/main.nim), and `create index concurrently` cannot run there.
-- The plain build takes a SHARE lock on community.invite, so writes to that
-- table wait while it runs; the table is small and this is one release (P-8).

create index if not exists invite_email_hash_pending_idx
  on community.invite (email_hash)
  where accepted_at is null;