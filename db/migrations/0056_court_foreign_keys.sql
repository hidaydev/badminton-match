-- 0056: a game's court is a row, so the court key can be a real foreign key.
--
-- DB-11 asks for `games_court_fk` and `game_skips_court_fk`. ADR-017 deferred
-- them because `session.courts` had no writer in v2: every v2 session has zero
-- court rows and every game names a court index, so a key would have rejected
-- the schedule writer while catching nothing. 0053 kept the coordinate honest
-- where a register existed and left the key deferred.
--
-- The reopener ADR-017 names is the session owning its court rows. This
-- migration makes that true at the database instead of in each writer: a game
-- whose session has no declared register materialises the court it names. Three
-- parts:
--
--   * `session.courts.declared` separates the two kinds of row. A declared row
--     is the register a session ships with (the v1 import writes them, and every
--     row that existed before this migration came from there, so the backfill
--     marks them declared). A materialised row is derived from a game and owns
--     nothing except the coordinate, so it is written with the session's own
--     start time and slot length.
--   * 0053's coordinate guard now reads `declared` instead of "has any row". An
--     imported session keeps refusing a coordinate outside its register, which
--     is the behaviour 0053 shipped; a v2 session accepts any coordinate and
--     gains the row.
--   * the backfill gives every game and skip that names a court without a row
--     its own, then both keys are added `deferrable initially deferred`, so a
--     session delete cascades its courts and its games in one statement and the
--     check sees the end state.
--
-- What this still does not do, and ADR-017 keeps saying: it does not decide how
-- many courts a session has, what a court is called, or whether a coordinate is
-- valid rather than merely present. That is a product answer (a declared court
-- set, a ceiling per session), and with materialisation every coordinate is
-- present by construction. A session that ships a register is still held to it.
--
-- The coordinate guard stays a separate function so the message keeps naming the
-- court and the session; the key is the backstop that no writer can skip.

alter table session.courts
  add column declared boolean not null default false;

-- Every row that exists now came from the import, which is the only writer that
-- ever filled the table: those are the register, not a materialised coordinate.
update session.courts set declared = true;

-- The intended end of the court window, in one place, for the backfill and the
-- materialising trigger. A slot length that is a whole day would put the end on
-- the start; `courts_time_order` refuses that, so a day is treated as a minute
-- for the register's purposes the row still needs to exist.
create or replace function session.court_end_time(
  p_start time, p_slot_minutes integer)
returns time
language sql immutable as $$
  select (p_start + make_interval(
    mins => case when p_slot_minutes % 1440 = 0 then 1
                 else p_slot_minutes % 1440 end))::time
$$;

-- The unique key the foreign key needs. `courts_session_index_unique` already
-- makes (session_id, court_index) unique, so this adds no new rejection; it
-- exists because a composite key must name its own unique constraint.
alter table session.courts
  add constraint courts_community_session_index_unique
  unique (community_id, session_id, court_index);

-- Backfill: one court row per coordinate a game already uses and has no row for.
-- Sessions that ship a register keep every coordinate inside it (0053 makes that
-- true for new writes), and `on conflict` leaves those untouched. A row that
-- predates the guard is repaired here rather than left to fail the key below.
insert into session.courts
  (community_id, session_id, court_index, start_time, end_time, declared)
select distinct g.community_id, g.session_id, g.court_no, s.start_time,
       session.court_end_time(s.start_time, s.slot_minutes), false
  from session.games g
  join session.sessions s
    on s.community_id = g.community_id and s.id = g.session_id
on conflict (community_id, session_id, court_index) do nothing;

-- The guard now asks about the register, not about whether any row exists.
create or replace function session.court_coordinate_exists(
  p_community uuid, p_session uuid, p_court integer)
returns boolean
language sql stable as $$
  select not exists (
           select 1 from session.courts c
            where c.community_id = p_community and c.session_id = p_session
              and c.declared)
      or exists (
           select 1 from session.courts c
            where c.community_id = p_community and c.session_id = p_session
              and c.court_index = p_court)
$$;

-- A session with no register owns its courts, so the game that names one gets
-- the row. The guard runs first (trigger names are ordered, and
-- `games_court_coordinate` sorts before `games_court_materialise`), so a session
-- that does ship a register never reaches this insert.
create or replace function session.court_materialise()
returns trigger
language plpgsql as $$
begin
  insert into session.courts
    (community_id, session_id, court_index, start_time, end_time, declared)
  select s.community_id, s.id, new.court_no, s.start_time,
         session.court_end_time(s.start_time, s.slot_minutes), false
    from session.sessions s
   where s.community_id = new.community_id and s.id = new.session_id
  on conflict (community_id, session_id, court_index) do nothing;
  return new;
end;
$$;

create trigger games_court_materialise
  before insert or update of community_id, session_id, court_no
  on session.games
  for each row
  execute function session.court_materialise();

-- A skip's court is its game's court (`game_skips_game_fk`), so the game's
-- materialisation already created the row; no second trigger is needed.

-- `no action` rather than `restrict`: a restriction is checked immediately even
-- on a deferrable key, and the session delete has to be able to remove a court
-- and its games in one statement.
alter table session.games
  add constraint games_court_fk
  foreign key (community_id, session_id, court_no)
  references session.courts (community_id, session_id, court_index)
  on delete no action
  deferrable initially deferred;

alter table session.game_skips
  add constraint game_skips_court_fk
  foreign key (community_id, session_id, court_no)
  references session.courts (community_id, session_id, court_index)
  on delete no action
  deferrable initially deferred;
