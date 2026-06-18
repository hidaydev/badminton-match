revoke execute on function bm.resolve_session_lookup(text) from anon, authenticated;
revoke execute on function bm.resolve_tournament_lookup(text) from anon, authenticated;
revoke execute on function bm.get_session_snapshot_compat(text) from anon, authenticated;
revoke execute on function bm.get_player_stats_compat(text) from anon, authenticated;
revoke execute on function bm.validate_session_snapshot(jsonb) from anon, authenticated;
revoke execute on function bm.validate_tournament_snapshot(jsonb) from anon, authenticated;

grant execute on function bm.resolve_session_lookup(text) to service_role;
grant execute on function bm.resolve_tournament_lookup(text) to service_role;
grant execute on function bm.get_session_snapshot_compat(text) to service_role;
grant execute on function bm.get_player_stats_compat(text) to service_role;
grant execute on function bm.validate_session_snapshot(jsonb) to service_role;
grant execute on function bm.validate_tournament_snapshot(jsonb) to service_role;

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname = 'bm_session_courts_session_internal_court_key'
      and conrelid = 'bm.session_courts'::regclass
  ) then
    alter table bm.session_courts
      add constraint bm_session_courts_session_internal_court_key
      unique (session_internal_id, court_index);
  end if;
end
$$;

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname = 'bm_session_players_session_internal_player_key'
      and conrelid = 'bm.session_players'::regclass
  ) then
    alter table bm.session_players
      add constraint bm_session_players_session_internal_player_key
      unique (session_internal_id, player_id);
  end if;
end
$$;

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname = 'bm_session_players_session_internal_player_ref_key'
      and conrelid = 'bm.session_players'::regclass
  ) then
    alter table bm.session_players
      add constraint bm_session_players_session_internal_player_ref_key
      unique (session_internal_id, player_ref);
  end if;
end
$$;

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname = 'bm_session_players_session_internal_sort_order_key'
      and conrelid = 'bm.session_players'::regclass
  ) then
    alter table bm.session_players
      add constraint bm_session_players_session_internal_sort_order_key
      unique (session_internal_id, sort_order);
  end if;
end
$$;

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname = 'bm_fix_matches_session_internal_legacy_ref_key'
      and conrelid = 'bm.fix_matches'::regclass
  ) then
    alter table bm.fix_matches
      add constraint bm_fix_matches_session_internal_legacy_ref_key
      unique (session_internal_id, legacy_ref);
  end if;
end
$$;

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname = 'bm_fix_matches_session_internal_sort_order_key'
      and conrelid = 'bm.fix_matches'::regclass
  ) then
    alter table bm.fix_matches
      add constraint bm_fix_matches_session_internal_sort_order_key
      unique (session_internal_id, sort_order);
  end if;
end
$$;

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname = 'bm_scheduled_games_session_internal_slot_court_key'
      and conrelid = 'bm.scheduled_games'::regclass
  ) then
    alter table bm.scheduled_games
      add constraint bm_scheduled_games_session_internal_slot_court_key
      unique (session_internal_id, slot_index, court_index);
  end if;
end
$$;

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname = 'bm_scheduled_games_session_internal_legacy_order_key'
      and conrelid = 'bm.scheduled_games'::regclass
  ) then
    alter table bm.scheduled_games
      add constraint bm_scheduled_games_session_internal_legacy_order_key
      unique (session_internal_id, legacy_order);
  end if;
end
$$;

create index if not exists bm_session_courts_session_internal_id_idx
  on bm.session_courts (session_internal_id);

create index if not exists bm_session_players_session_internal_id_idx
  on bm.session_players (session_internal_id);

create index if not exists bm_fix_matches_session_internal_id_idx
  on bm.fix_matches (session_internal_id);

create index if not exists bm_scheduled_games_session_internal_id_idx
  on bm.scheduled_games (session_internal_id);
