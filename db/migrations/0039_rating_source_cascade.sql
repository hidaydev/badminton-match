-- 0039: a rating event and its sign-off row cannot outlive their source.
--
-- `rating.events.source_id` and `rating.sources.source_id` carried no
-- reference, so deleting a session left its event behind: the board still read
-- the date from it while the join to `session.game_results` found nothing, and
-- the one-event index blocked a later session with the same id. The source
-- tables cascade their own event here, because a delete from the application
-- already reverts the event and rebuilds the counters before it removes the
-- session.
create or replace function rating.drop_source_rows() returns trigger
language plpgsql as $$
begin
  delete from rating.events
   where community_id = old.community_id
     and source_id = old.id
     and event_type = tg_argv[0];
  delete from rating.sources
   where community_id = old.community_id
     and source_id = old.id;
  return old;
end;
$$;

create trigger sessions_drop_rating_source
  before delete on session.sessions
  for each row execute function rating.drop_source_rows('session');

create trigger tournaments_drop_rating_source
  before delete on tournament.tournaments
  for each row execute function rating.drop_source_rows('tournament');
