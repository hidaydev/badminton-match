-- 0043: indexes for the rows the janitor now deletes.
--
-- Expired links, expired login sessions, accepted or expired invites and
-- revoked ops tokens had no predicate-friendly index, so the new purge targets
-- would each scan the table. The partial indexes match the janitor predicates,
-- except account.sessions where the whole row set is temporary.
create index if not exists links_expiry_idx
  on session.links (expires_at)
  where expires_at is not null and revoked_at is null;

create index if not exists account_sessions_expiry_idx
  on account.sessions (absolute_expires_at);

create index if not exists invite_expiry_idx
  on community.invite (expires_at)
  where expires_at is not null and accepted_at is null;

create index if not exists invite_accepted_idx
  on community.invite (accepted_at)
  where accepted_at is not null;

create index if not exists ops_token_expired_revoked_idx
  on platform.ops_token (expires_at)
  where revoked_at is not null;
