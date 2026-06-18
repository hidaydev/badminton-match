do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname = 'bm_session_players_id_internal_id_key'
      and conrelid = 'bm.session_players'::regclass
  ) then
    alter table bm.session_players
      add constraint bm_session_players_id_internal_id_key
      unique (id, internal_id);
  end if;
end
$$;

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname = 'bm_fix_matches_id_internal_id_key'
      and conrelid = 'bm.fix_matches'::regclass
  ) then
    alter table bm.fix_matches
      add constraint bm_fix_matches_id_internal_id_key
      unique (id, internal_id);
  end if;
end
$$;

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname = 'bm_scheduled_games_id_internal_id_key'
      and conrelid = 'bm.scheduled_games'::regclass
  ) then
    alter table bm.scheduled_games
      add constraint bm_scheduled_games_id_internal_id_key
      unique (id, internal_id);
  end if;
end
$$;

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname = 'bm_fix_match_slots_fix_match_identity_fk'
      and conrelid = 'bm.fix_match_slots'::regclass
  ) then
    alter table bm.fix_match_slots
      add constraint bm_fix_match_slots_fix_match_identity_fk
      foreign key (fix_match_id, fix_match_internal_id)
      references bm.fix_matches (id, internal_id)
      on delete cascade;
  end if;
end
$$;

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname = 'bm_fix_match_slots_session_player_identity_fk'
      and conrelid = 'bm.fix_match_slots'::regclass
  ) then
    alter table bm.fix_match_slots
      add constraint bm_fix_match_slots_session_player_identity_fk
      foreign key (session_player_id, session_player_internal_id)
      references bm.session_players (id, internal_id)
      on delete set null;
  end if;
end
$$;

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

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname = 'bm_scheduled_game_players_game_identity_fk'
      and conrelid = 'bm.scheduled_game_players'::regclass
  ) then
    alter table bm.scheduled_game_players
      add constraint bm_scheduled_game_players_game_identity_fk
      foreign key (scheduled_game_id, scheduled_game_internal_id)
      references bm.scheduled_games (id, internal_id)
      on delete cascade;
  end if;
end
$$;

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname = 'bm_scheduled_game_players_session_player_identity_fk'
      and conrelid = 'bm.scheduled_game_players'::regclass
  ) then
    alter table bm.scheduled_game_players
      add constraint bm_scheduled_game_players_session_player_identity_fk
      foreign key (session_player_id, session_player_internal_id)
      references bm.session_players (id, internal_id)
      on delete cascade;
  end if;
end
$$;

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

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname = 'bm_game_progress_scheduled_game_identity_fk'
      and conrelid = 'bm.game_progress'::regclass
  ) then
    alter table bm.game_progress
      add constraint bm_game_progress_scheduled_game_identity_fk
      foreign key (scheduled_game_id, scheduled_game_internal_id)
      references bm.scheduled_games (id, internal_id)
      on delete cascade;
  end if;
end
$$;

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname = 'bm_game_progress_scheduled_game_internal_key'
      and conrelid = 'bm.game_progress'::regclass
  ) then
    alter table bm.game_progress
      add constraint bm_game_progress_scheduled_game_internal_key
      unique (scheduled_game_internal_id);
  end if;
end
$$;

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname = 'bm_game_scores_scheduled_game_identity_fk'
      and conrelid = 'bm.game_scores'::regclass
  ) then
    alter table bm.game_scores
      add constraint bm_game_scores_scheduled_game_identity_fk
      foreign key (scheduled_game_id, scheduled_game_internal_id)
      references bm.scheduled_games (id, internal_id)
      on delete cascade;
  end if;
end
$$;

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname = 'bm_game_scores_scheduled_game_internal_key'
      and conrelid = 'bm.game_scores'::regclass
  ) then
    alter table bm.game_scores
      add constraint bm_game_scores_scheduled_game_internal_key
      unique (scheduled_game_internal_id);
  end if;
end
$$;
