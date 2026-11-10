-- 0053: a schedule coordinate names a court the session actually has.
--
-- DB-11 asks for `session.games_court_fk` and `session.game_skips_court_fk`.
-- ADR-017 records why the foreign key itself cannot be added: `session.courts`
-- has no writer in v2, only the v1 import fills it, and every game the schedule
-- writer creates names a court index that has no row. A foreign key would reject
-- that writer and catch nothing that exists.
--
-- This migration keeps what the key is for without that cost. When a session has
-- a court register, a game or a skip may only name a court in it, and a court
-- row a game still uses cannot be deleted or renumbered. A session with no court
-- rows is unchanged, which is every v2 session today; the sharpest part of the
-- finding, the coordinate itself, is already covered by
-- `0051_game_skips_game_fk`.
--
-- The register is still the authority where it exists, so a generated game on
-- `court_no = 99` fails here instead of rendering a phantom court. Deleting a
-- session cascades to its courts, games and skips in one statement; once the
-- session row is gone the guard stands down, because nothing it protects can
-- outlive it.

create or replace function session.court_coordinate_exists(
  p_community uuid, p_session uuid, p_court integer)
returns boolean
language sql stable as $$
  select not exists (
           select 1 from session.courts c
            where c.community_id = p_community and c.session_id = p_session)
      or exists (
           select 1 from session.courts c
            where c.community_id = p_community and c.session_id = p_session
              and c.court_index = p_court)
$$;

create or replace function session.court_coordinate_guard()
returns trigger
language plpgsql as $$
begin
  if not session.court_coordinate_exists(new.community_id, new.session_id,
                                         new.court_no) then
    raise exception 'court % does not exist in session %', new.court_no,
      new.session_id
      using errcode = '23503',
            hint = 'create the session.courts row first, or use a court the session owns';
  end if;
  return new;
end;
$$;

create trigger games_court_coordinate
  before insert or update of community_id, session_id, court_no
  on session.games
  for each row
  execute function session.court_coordinate_guard();

create trigger game_skips_court_coordinate
  before insert or update of community_id, session_id, court_no
  on session.game_skips
  for each row
  execute function session.court_coordinate_guard();

create or replace function session.court_still_in_use()
returns trigger
language plpgsql as $$
declare
  referenced integer := old.court_index;
begin
  -- A session delete removes its courts and its games in one statement, and the
  -- order between the two cascades is not promised. With the session gone the
  -- court cannot orphan anything that outlives it.
  if not exists (
      select 1 from session.sessions s
       where s.community_id = old.community_id and s.id = old.session_id) then
    if tg_op = 'UPDATE' then return new; else return old; end if;
  end if;

  if exists (
      select 1 from session.games g
       where g.community_id = old.community_id
         and g.session_id = old.session_id
         and g.court_no = referenced)
     or exists (
      select 1 from session.game_skips k
       where k.community_id = old.community_id
         and k.session_id = old.session_id
         and k.court_no = referenced) then
    raise exception 'court % of session % still has games', referenced,
      old.session_id
      using errcode = '23503',
            hint = 'move the games to another court, or delete them first';
  end if;

  if tg_op = 'UPDATE' then return new; else return old; end if;
end;
$$;

create trigger courts_court_still_in_use
  before delete or update of court_index
  on session.courts
  for each row
  execute function session.court_still_in_use();
