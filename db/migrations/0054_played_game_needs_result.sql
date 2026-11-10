-- 0054: a game cannot become `played` without a set once its session is rated.
--
-- DB-08: `status = 'played'` is a host flag before the score, which is honest
-- while the session is a draft (`setPlayed` in `modules/session/schedule.nim`).
-- Once the session is locked the game is rated, and a played game with no set
-- makes the two readers disagree: the session page counts it, while
-- `session.game_results` answers `winner = ''` and the projection drops it.
--
-- `0052_approved_session_needs_results.sql` guards the approval transition and
-- moved five imported rows in locked sessions to `cancelled`. It left the game
-- row itself open, and the writer that still produced the shape is the v1
-- import, which copies the flag without the score. Two changes close it:
--
--   * the import now writes `cancelled` for a played row with no score, so a
--     rerun cannot recreate the five rows;
--   * the trigger below refuses the transition outside a draft, at the database,
--     so a writer that skips the handler is stopped too.
--
-- The check is deferred to commit because the write order is game first, set
-- second (`setSets` inserts the sets, then the status, in one transaction, and
-- the import inserts the game, then its set, in one transaction). Checking per
-- statement would refuse that order while a row is half-written. An insert is
-- still unchecked on purpose: the marking feature and the import both write the
-- game row before its score exists, and the only insert writer is the import,
-- which is fixed above. The transition is what remains reachable.

update session.games g
   set status = 'cancelled'
 where g.status = 'played'
   and not exists (
       select 1 from session.game_sets x
       where x.community_id = g.community_id
         and x.session_id = g.session_id
         and x.round_no = g.round_no
         and x.court_no = g.court_no)
   and exists (
       select 1 from session.sessions s
       where s.community_id = g.community_id and s.id = g.session_id
         and s.status <> 'draft');

create or replace function session.played_game_needs_result()
returns trigger
language plpgsql as $$
declare
  session_status text;
begin
  if new.status <> 'played' then
    return null;
  end if;
  -- The row may have been removed again inside the same transaction, and its
  -- sets with it. Nothing persists, so there is nothing to refuse.
  if not exists (select 1 from session.games g where g.id = new.id) then
    return null;
  end if;
  if exists (
      select 1 from session.game_sets x
       where x.community_id = new.community_id
         and x.session_id = new.session_id
         and x.round_no = new.round_no
         and x.court_no = new.court_no) then
    return null;
  end if;

  select s.status into session_status
    from session.sessions s
   where s.community_id = new.community_id and s.id = new.session_id;
  if session_status is not distinct from 'draft' then
    return null;
  end if;

  raise exception 'a game in session % is played with no set', new.session_id
    using errcode = '23514',
          hint = 'enter the score, mark the game cancelled, or unlock the session';
end;
$$;

create constraint trigger games_played_needs_result
  after update of status on session.games
  deferrable initially deferred
  for each row
  execute function session.played_game_needs_result();
