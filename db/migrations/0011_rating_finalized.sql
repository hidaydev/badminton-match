-- A rating event can be signed off by an admin. The flag is the v2 port of
-- v1 `rating_sources.finalized`: a finalized source is no longer touched by
-- the incremental paths (ticker, revert), only by an explicit full rebuild.
alter table rating.events
  add column finalized boolean not null default false,
  add column finalized_at timestamp with time zone;

comment on column rating.events.finalized is
  'admin sign-off; cleared only by an explicit full rebuild';
comment on column rating.events.finalized_at is
  'when the sign-off happened; null while finalized is false';
