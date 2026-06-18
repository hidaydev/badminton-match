alter table bm.session_courts
  add column if not exists internal_id uuid;

update bm.session_courts
set internal_id = gen_random_uuid()
where internal_id is null;

alter table bm.session_courts
  alter column internal_id set default gen_random_uuid();

alter table bm.session_courts
  alter column internal_id set not null;

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname = 'bm_session_courts_internal_id_key'
      and conrelid = 'bm.session_courts'::regclass
  ) then
    alter table bm.session_courts
      add constraint bm_session_courts_internal_id_key unique (internal_id);
  end if;
end
$$;

alter table bm.fix_match_slots
  add column if not exists internal_id uuid;

update bm.fix_match_slots
set internal_id = gen_random_uuid()
where internal_id is null;

alter table bm.fix_match_slots
  alter column internal_id set default gen_random_uuid();

alter table bm.fix_match_slots
  alter column internal_id set not null;

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname = 'bm_fix_match_slots_internal_id_key'
      and conrelid = 'bm.fix_match_slots'::regclass
  ) then
    alter table bm.fix_match_slots
      add constraint bm_fix_match_slots_internal_id_key unique (internal_id);
  end if;
end
$$;

alter table bm.scheduled_game_players
  add column if not exists internal_id uuid;

update bm.scheduled_game_players
set internal_id = gen_random_uuid()
where internal_id is null;

alter table bm.scheduled_game_players
  alter column internal_id set default gen_random_uuid();

alter table bm.scheduled_game_players
  alter column internal_id set not null;

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname = 'bm_scheduled_game_players_internal_id_key'
      and conrelid = 'bm.scheduled_game_players'::regclass
  ) then
    alter table bm.scheduled_game_players
      add constraint bm_scheduled_game_players_internal_id_key unique (internal_id);
  end if;
end
$$;

drop trigger if exists bm_fix_match_slots_sync_identities on bm.fix_match_slots;
drop trigger if exists bm_scheduled_game_players_sync_identities on bm.scheduled_game_players;
drop trigger if exists bm_game_progress_sync_scheduled_game_identity on bm.game_progress;
drop trigger if exists bm_game_scores_sync_scheduled_game_identity on bm.game_scores;

drop function if exists bm.sync_fix_match_slot_identities();
drop function if exists bm.sync_scheduled_game_player_identities();
drop function if exists bm.sync_scheduled_game_identity();

alter table bm.fix_match_slots
  drop constraint if exists bm_fix_match_slots_fix_match_identity_fk,
  drop constraint if exists bm_fix_match_slots_session_player_identity_fk,
  drop constraint if exists bm_fix_match_slots_fix_match_slot_key,
  drop column if exists fix_match_id,
  drop column if exists session_player_id;

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname = 'bm_fix_match_slots_fix_match_internal_slot_key'
      and conrelid = 'bm.fix_match_slots'::regclass
  ) then
    alter table bm.fix_match_slots
      add constraint bm_fix_match_slots_fix_match_internal_slot_key
      unique (fix_match_internal_id, slot_index);
  end if;
end
$$;

alter table bm.scheduled_game_players
  drop constraint if exists bm_scheduled_game_players_game_identity_fk,
  drop constraint if exists bm_scheduled_game_players_session_player_identity_fk,
  drop constraint if exists bm_scheduled_game_players_team_position_key,
  drop constraint if exists bm_scheduled_game_players_session_player_key,
  drop column if exists scheduled_game_id,
  drop column if exists session_player_id;

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname = 'bm_scheduled_game_players_game_internal_team_pos_key'
      and conrelid = 'bm.scheduled_game_players'::regclass
  ) then
    alter table bm.scheduled_game_players
      add constraint bm_scheduled_game_players_game_internal_team_pos_key
      unique (scheduled_game_internal_id, team, position);
  end if;
end
$$;

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname = 'bm_scheduled_game_players_game_internal_player_key'
      and conrelid = 'bm.scheduled_game_players'::regclass
  ) then
    alter table bm.scheduled_game_players
      add constraint bm_scheduled_game_players_game_internal_player_key
      unique (scheduled_game_internal_id, session_player_internal_id);
  end if;
end
$$;

alter table bm.game_progress
  drop constraint if exists bm_game_progress_scheduled_game_identity_fk,
  drop constraint if exists game_progress_pkey,
  drop column if exists scheduled_game_id;

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname = 'bm_game_progress_pkey'
      and conrelid = 'bm.game_progress'::regclass
  ) then
    alter table bm.game_progress
      add constraint bm_game_progress_pkey
      primary key (scheduled_game_internal_id);
  end if;
end
$$;

alter table bm.game_scores
  drop constraint if exists bm_game_scores_scheduled_game_identity_fk,
  drop constraint if exists game_scores_pkey,
  drop column if exists scheduled_game_id;

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname = 'bm_game_scores_pkey'
      and conrelid = 'bm.game_scores'::regclass
  ) then
    alter table bm.game_scores
      add constraint bm_game_scores_pkey
      primary key (scheduled_game_internal_id);
  end if;
end
$$;
