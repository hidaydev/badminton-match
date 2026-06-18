alter table bm.session_players
  add column if not exists internal_id uuid;

update bm.session_players
set internal_id = gen_random_uuid()
where internal_id is null;

alter table bm.session_players
  alter column internal_id set default gen_random_uuid();

alter table bm.session_players
  alter column internal_id set not null;

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname = 'bm_session_players_internal_id_key'
      and conrelid = 'bm.session_players'::regclass
  ) then
    alter table bm.session_players
      add constraint bm_session_players_internal_id_key unique (internal_id);
  end if;
end
$$;

alter table bm.fix_matches
  add column if not exists internal_id uuid;

update bm.fix_matches
set internal_id = gen_random_uuid()
where internal_id is null;

alter table bm.fix_matches
  alter column internal_id set default gen_random_uuid();

alter table bm.fix_matches
  alter column internal_id set not null;

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname = 'bm_fix_matches_internal_id_key'
      and conrelid = 'bm.fix_matches'::regclass
  ) then
    alter table bm.fix_matches
      add constraint bm_fix_matches_internal_id_key unique (internal_id);
  end if;
end
$$;

alter table bm.scheduled_games
  add column if not exists internal_id uuid;

update bm.scheduled_games
set internal_id = gen_random_uuid()
where internal_id is null;

alter table bm.scheduled_games
  alter column internal_id set default gen_random_uuid();

alter table bm.scheduled_games
  alter column internal_id set not null;

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname = 'bm_scheduled_games_internal_id_key'
      and conrelid = 'bm.scheduled_games'::regclass
  ) then
    alter table bm.scheduled_games
      add constraint bm_scheduled_games_internal_id_key unique (internal_id);
  end if;
end
$$;

alter table bm.fix_match_slots
  add column if not exists fix_match_internal_id uuid,
  add column if not exists session_player_internal_id uuid;

update bm.fix_match_slots fms
set fix_match_internal_id = fm.internal_id,
    session_player_internal_id = (
      select sp.internal_id
      from bm.session_players sp
      where sp.id = fms.session_player_id
    )
from bm.fix_matches fm
where fm.id = fms.fix_match_id
  and (
    fms.fix_match_internal_id is null
    or (
      fms.session_player_id is not null
      and fms.session_player_internal_id is null
    )
  );

alter table bm.fix_match_slots
  alter column fix_match_internal_id set not null;

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname = 'bm_fix_match_slots_fix_match_internal_fk'
      and conrelid = 'bm.fix_match_slots'::regclass
  ) then
    alter table bm.fix_match_slots
      add constraint bm_fix_match_slots_fix_match_internal_fk
      foreign key (fix_match_internal_id)
      references bm.fix_matches (internal_id)
      on delete cascade;
  end if;
end
$$;

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname = 'bm_fix_match_slots_session_player_internal_fk'
      and conrelid = 'bm.fix_match_slots'::regclass
  ) then
    alter table bm.fix_match_slots
      add constraint bm_fix_match_slots_session_player_internal_fk
      foreign key (session_player_internal_id)
      references bm.session_players (internal_id)
      on delete set null;
  end if;
end
$$;

create index if not exists bm_fix_match_slots_fix_match_internal_id_idx
  on bm.fix_match_slots (fix_match_internal_id);

create index if not exists bm_fix_match_slots_session_player_internal_id_idx
  on bm.fix_match_slots (session_player_internal_id);

alter table bm.scheduled_game_players
  add column if not exists scheduled_game_internal_id uuid,
  add column if not exists session_player_internal_id uuid;

update bm.scheduled_game_players sgp
set scheduled_game_internal_id = sg.internal_id,
    session_player_internal_id = sp.internal_id
from bm.scheduled_games sg,
     bm.session_players sp
where sg.id = sgp.scheduled_game_id
  and sp.id = sgp.session_player_id
  and (
    sgp.scheduled_game_internal_id is null
    or sgp.session_player_internal_id is null
  );

alter table bm.scheduled_game_players
  alter column scheduled_game_internal_id set not null;

alter table bm.scheduled_game_players
  alter column session_player_internal_id set not null;

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname = 'bm_scheduled_game_players_game_internal_fk'
      and conrelid = 'bm.scheduled_game_players'::regclass
  ) then
    alter table bm.scheduled_game_players
      add constraint bm_scheduled_game_players_game_internal_fk
      foreign key (scheduled_game_internal_id)
      references bm.scheduled_games (internal_id)
      on delete cascade;
  end if;
end
$$;

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname = 'bm_scheduled_game_players_session_player_internal_fk'
      and conrelid = 'bm.scheduled_game_players'::regclass
  ) then
    alter table bm.scheduled_game_players
      add constraint bm_scheduled_game_players_session_player_internal_fk
      foreign key (session_player_internal_id)
      references bm.session_players (internal_id)
      on delete cascade;
  end if;
end
$$;

create index if not exists bm_scheduled_game_players_game_internal_id_idx
  on bm.scheduled_game_players (scheduled_game_internal_id);

create index if not exists bm_scheduled_game_players_session_player_internal_id_idx
  on bm.scheduled_game_players (session_player_internal_id);

alter table bm.game_progress
  add column if not exists scheduled_game_internal_id uuid;

update bm.game_progress gp
set scheduled_game_internal_id = sg.internal_id
from bm.scheduled_games sg
where sg.id = gp.scheduled_game_id
  and gp.scheduled_game_internal_id is null;

alter table bm.game_progress
  alter column scheduled_game_internal_id set not null;

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname = 'bm_game_progress_scheduled_game_internal_fk'
      and conrelid = 'bm.game_progress'::regclass
  ) then
    alter table bm.game_progress
      add constraint bm_game_progress_scheduled_game_internal_fk
      foreign key (scheduled_game_internal_id)
      references bm.scheduled_games (internal_id)
      on delete cascade;
  end if;
end
$$;

create index if not exists bm_game_progress_scheduled_game_internal_id_idx
  on bm.game_progress (scheduled_game_internal_id);

alter table bm.game_scores
  add column if not exists scheduled_game_internal_id uuid;

update bm.game_scores gs
set scheduled_game_internal_id = sg.internal_id
from bm.scheduled_games sg
where sg.id = gs.scheduled_game_id
  and gs.scheduled_game_internal_id is null;

alter table bm.game_scores
  alter column scheduled_game_internal_id set not null;

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname = 'bm_game_scores_scheduled_game_internal_fk'
      and conrelid = 'bm.game_scores'::regclass
  ) then
    alter table bm.game_scores
      add constraint bm_game_scores_scheduled_game_internal_fk
      foreign key (scheduled_game_internal_id)
      references bm.scheduled_games (internal_id)
      on delete cascade;
  end if;
end
$$;

create index if not exists bm_game_scores_scheduled_game_internal_id_idx
  on bm.game_scores (scheduled_game_internal_id);
