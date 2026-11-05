-- 0023: one event per rating source.
--
-- Two ingests can race past the "this source already has an event" check and
-- both insert one. The advisory lock added alongside this migration serialises
-- the writers; the index makes a second event impossible even if a caller
-- forgets the lock.
--
-- An existing duplicate cannot be indexed, and silently deleting events would
-- drop real points. Fail loudly so the operator chooses which event to keep.
do $$
begin
  if exists (
    select 1 from rating.events
    where event_type in ('session', 'tournament') and source_id is not null
    group by community_id, event_type, source_id
    having count(*) > 1
  ) then
    raise exception
      'rating.events has duplicate events for one source; resolve them before applying 0023';
  end if;
end $$;

create unique index if not exists rating_events_source_once
  on rating.events (community_id, event_type, source_id)
  where event_type in ('session', 'tournament') and source_id is not null;