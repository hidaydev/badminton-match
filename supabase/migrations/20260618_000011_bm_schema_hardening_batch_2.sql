do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname = 'bm_players_canonical_name_not_blank_ck'
      and conrelid = 'bm.players'::regclass
  ) then
    alter table bm.players
      add constraint bm_players_canonical_name_not_blank_ck
      check (trim(canonical_name) <> '');
  end if;
end
$$;

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname = 'bm_sessions_id_not_blank_ck'
      and conrelid = 'bm.sessions'::regclass
  ) then
    alter table bm.sessions
      add constraint bm_sessions_id_not_blank_ck
      check (trim(id) <> '');
  end if;
end
$$;

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname = 'bm_session_players_source_name_not_blank_ck'
      and conrelid = 'bm.session_players'::regclass
  ) then
    alter table bm.session_players
      add constraint bm_session_players_source_name_not_blank_ck
      check (trim(source_name) <> '');
  end if;
end
$$;

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname = 'bm_fix_matches_legacy_ref_not_blank_ck'
      and conrelid = 'bm.fix_matches'::regclass
  ) then
    alter table bm.fix_matches
      add constraint bm_fix_matches_legacy_ref_not_blank_ck
      check (trim(legacy_ref) <> '');
  end if;
end
$$;

alter table bm.tournaments
  add column if not exists created_at timestamptz;

update bm.tournaments
set created_at = coalesce(created_at, updated_at, now())
where created_at is null;

alter table bm.tournaments
  alter column created_at set default now();

alter table bm.tournaments
  alter column created_at set not null;

create index if not exists bm_session_courts_session_id_idx
  on bm.session_courts (session_id);

create index if not exists bm_fix_matches_session_id_idx
  on bm.fix_matches (session_id);

create index if not exists bm_fix_match_slots_session_player_id_idx
  on bm.fix_match_slots (session_player_id)
  where session_player_id is not null;

create index if not exists bm_session_players_session_absent_order_idx
  on bm.session_players (session_id, is_absent, absent_order, sort_order);

create index if not exists bm_game_progress_played_order_idx
  on bm.game_progress (played_order)
  where is_played;

create index if not exists bm_tournaments_event_date_idx
  on bm.tournaments (event_date desc);

create index if not exists bm_tournaments_updated_at_idx
  on bm.tournaments (updated_at desc);

drop trigger if exists bm_tournaments_set_updated_at on bm.tournaments;
create trigger bm_tournaments_set_updated_at
before update on bm.tournaments
for each row
execute function bm.set_updated_at();

drop trigger if exists bm_game_progress_set_updated_at on bm.game_progress;
create trigger bm_game_progress_set_updated_at
before update on bm.game_progress
for each row
execute function bm.set_updated_at();
