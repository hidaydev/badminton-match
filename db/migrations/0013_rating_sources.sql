-- 0013: a rating source has its own sign-off row.
--
-- v1 kept `rating_sources.finalized` next to the source, so a tournament could
-- be cleared for ingest BEFORE any event existed. 0011 put the flag on the
-- event, which made that impossible. This moves it to a source table keyed by
-- the id that produced the event (session or tournament), and removes the
-- event columns so there is a single truth. A full rebuild recomputes events
-- but leaves sources untouched, so a sign-off now survives it.
create table rating.sources (
  community_id uuid not null references platform.community(id) on delete restrict,
  source_id uuid not null,
  kind text not null,
  finalized boolean not null default false,
  finalized_at timestamp with time zone,
  created_at timestamp with time zone not null default now(),
  constraint sources_pk primary key (community_id, source_id),
  constraint sources_kind_check check (kind in ('session', 'tournament'))
);

alter table rating.events
  drop column finalized_at,
  drop column finalized;

grant select, insert, update, delete on rating.sources to bm2_app;
