-- 0006: approval stamp for a locked session.
--
-- Locking a session is the moment its schedule is approved, so the row records
-- who did it and when. Unlocking clears both fields; history stays in
-- account.audit rather than in a nullable timestamp.

alter table session.sessions
  add column if not exists approved_at timestamptz,
  add column if not exists approved_by uuid references platform.user(id) on delete set null;

create index if not exists sessions_community_approved_idx
  on session.sessions (community_id, approved_at desc)
  where approved_at is not null;
