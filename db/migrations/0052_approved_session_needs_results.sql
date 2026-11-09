-- 0052: an approved session cannot hold a played game with no result.
--
-- `status = 'played'` is a host flag, not a result: a host marks a game played
-- before entering its score (`modules/session/schedule.nim`, `setPlayed`), and
-- v1 carried the same flag next to an empty score. The flag is honest while the
-- session is a draft. Once the session is approved it is rated, and the two
-- readers disagree about a played game with no set: the session page counts it
-- while `session.game_results` answers `winner = ''` and the projection drops
-- it. Five imported rows in bm2_explore sat inside locked sessions and
-- contributed nothing to the session they appeared to belong to.
--
-- Approval is therefore the gate. A session that becomes approved while a
-- played game has no set is refused, so the interactive path can no longer
-- create the silent hole, and the legacy rows move to `cancelled`, which is what
-- a game nobody ever scored is.
--
-- The game row itself keeps accepting `played` without a set: that is the
-- marking feature, and the import writes the same v1 flag next to the session
-- it creates. The check therefore sits on the approval transition rather than on
-- every game write, so a session that is created already approved (the import,
-- or a fixture) is not refused here. Reconciling the imported flag is a
-- separate, product-shaped change.
update session.games g
   set status = 'cancelled'
 where g.status = 'played'
   and exists (
       select 1 from session.sessions s
       where s.community_id = g.community_id and s.id = g.session_id
         and s.status in ('locked', 'published', 'completed', 'archived'))
   and not exists (
       select 1 from session.game_sets x
       where x.community_id = g.community_id
         and x.session_id = g.session_id
         and x.round_no = g.round_no
         and x.court_no = g.court_no);

create or replace function session.approved_session_needs_results()
returns trigger
language plpgsql as $$
begin
  if exists (
    select 1
    from session.games g
    where g.community_id = new.community_id
      and g.session_id = new.id
      and g.status = 'played'
      and not exists (
        select 1 from session.game_sets x
        where x.community_id = g.community_id
          and x.session_id = g.session_id
          and x.round_no = g.round_no
          and x.court_no = g.court_no)
  ) then
    raise exception 'session % is approved with a played game that has no score', new.id
      using errcode = '23514',
            hint = 'enter the score, mark the game cancelled, or unmark it played';
  end if;
  return new;
end;
$$;

create trigger sessions_approval_needs_results
  before update of status on session.sessions
  for each row
  when (new.status in ('locked', 'published', 'completed', 'archived')
        and new.status is distinct from old.status)
  execute function session.approved_session_needs_results();
