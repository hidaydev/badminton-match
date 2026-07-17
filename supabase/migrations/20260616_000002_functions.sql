-- ============================================================================
-- SQUASHED FUNCTIONS: Final state of all bm.* and public.* RPCs
-- ============================================================================
-- This migration contains CREATE OR REPLACE for all functions. It is safe to
-- apply on any database that has run all prior migrations — the final state
-- will be identical regardless of which intermediate rewrites were applied.
--
-- Source: Extracted from migrations 000003 through 000052.
-- ============================================================================

-- ─────────────────────────────────────────────────────────────────────
-- bm.normalize_player_name
-- Source: 000003 (never rewritten)
-- ─────────────────────────────────────────────────────────────────────
create or replace function bm.normalize_player_name(p_name text)
returns text
language sql
immutable
as $$
  select nullif(
    regexp_replace(lower(trim(coalesce(p_name, ''))), '\s+', ' ', 'g'),
    ''
  );
$$;

-- ─────────────────────────────────────────────────────────────────────
-- bm.ensure_player
-- Source: 000003 (never rewritten)
-- ─────────────────────────────────────────────────────────────────────
create or replace function bm.ensure_player(p_canonical_name text)
returns uuid
language plpgsql
security definer
set search_path = bm, public
as $$
declare
  v_canonical_name text := trim(coalesce(p_canonical_name, ''));
  v_alias_name text;
  v_player_id uuid;
begin
  if v_canonical_name = '' then
    raise exception 'canonical player name must not be blank';
  end if;

  insert into bm.players (canonical_name)
  values (v_canonical_name)
  on conflict (canonical_name) do update
    set canonical_name = excluded.canonical_name,
        updated_at = now()
  returning id into v_player_id;

  v_alias_name := bm.normalize_player_name(v_canonical_name);

  insert into bm.player_aliases (alias_name, player_id)
  values (v_alias_name, v_player_id)
  on conflict (alias_name) do update
    set player_id = excluded.player_id;

  return v_player_id;
end;
$$;

grant execute on function bm.ensure_player(text) to service_role;

-- ─────────────────────────────────────────────────────────────────────
-- bm.validate_session_snapshot
-- Source: 000031 (20260618_000031_bm_validate_session_snapshot_record_alias_fix.sql)
-- ─────────────────────────────────────────────────────────────────────
create or replace function bm.validate_session_snapshot(p_snapshot jsonb)
returns void
language plpgsql
security definer
set search_path = bm, public
as $$
declare
  v_courts integer := coalesce(nullif(p_snapshot->'session'->>'courts', '')::integer, 0);
  v_player_count integer;
  v_schedule_count integer;
begin
  if p_snapshot is null then
    raise exception 'session snapshot must not be null';
  end if;

  if jsonb_typeof(p_snapshot) <> 'object' then
    raise exception 'session snapshot must be a json object';
  end if;

  if jsonb_typeof(coalesce(p_snapshot->'session', 'null'::jsonb)) <> 'object' then
    raise exception 'session snapshot.session must be an object';
  end if;

  if coalesce(p_snapshot->'session'->>'date', '') = '' then
    raise exception 'session snapshot.session.date must not be blank';
  end if;

  perform (p_snapshot->'session'->>'date')::date;

  if coalesce(p_snapshot->'session'->>'sessionStart', '') <> '' then
    perform (p_snapshot->'session'->>'sessionStart')::time;
  end if;

  if coalesce(p_snapshot->'session'->>'slotMinutes', '') <> ''
     and (p_snapshot->'session'->>'slotMinutes')::integer <= 0 then
    raise exception 'session snapshot.session.slotMinutes must be positive';
  end if;

  if jsonb_typeof(coalesce(p_snapshot->'players', 'null'::jsonb)) <> 'array' then
    raise exception 'session snapshot.players must be an array';
  end if;

  if jsonb_typeof(coalesce(p_snapshot->'fixMatches', 'null'::jsonb)) <> 'array' then
    raise exception 'session snapshot.fixMatches must be an array';
  end if;

  if jsonb_typeof(coalesce(p_snapshot->'schedule', 'null'::jsonb)) <> 'array' then
    raise exception 'session snapshot.schedule must be an array';
  end if;

  if jsonb_typeof(coalesce(p_snapshot->'playedGames', 'null'::jsonb)) <> 'array' then
    raise exception 'session snapshot.playedGames must be an array';
  end if;

  if jsonb_typeof(coalesce(p_snapshot->'gameScores', 'null'::jsonb)) <> 'object' then
    raise exception 'session snapshot.gameScores must be an object';
  end if;

  if p_snapshot ? 'absentPlayers'
     and jsonb_typeof(coalesce(p_snapshot->'absentPlayers', 'null'::jsonb)) <> 'array' then
    raise exception 'session snapshot.absentPlayers must be an array when present';
  end if;

  select count(*)
  into v_player_count
  from jsonb_array_elements(p_snapshot->'players') as player_item(value);

  if exists (
    select 1
    from jsonb_array_elements(p_snapshot->'players') as player_item(value)
    where jsonb_typeof(player_item.value) <> 'object'
       or trim(coalesce(player_item.value->>'id', '')) = ''
       or trim(coalesce(player_item.value->>'name', '')) = ''
       or coalesce(player_item.value->>'gender', 'M') not in ('M', 'F')
       or coalesce(nullif(player_item.value->>'tier', '')::integer, 1) not between 1 and 4
  ) then
    raise exception 'session players must contain non-blank id/name and valid gender/tier values';
  end if;

  if exists (
    select 1
    from (
      select trim(player_item.value->>'id') as player_ref, count(*) as c
      from jsonb_array_elements(p_snapshot->'players') as player_item(value)
      group by trim(player_item.value->>'id')
      having count(*) > 1
    ) dup_player
  ) then
    raise exception 'session player ids must be unique';
  end if;

  if p_snapshot->'session' ? 'playerCount'
     and coalesce(nullif(p_snapshot->'session'->>'playerCount', '')::integer, -1) <> v_player_count then
    raise exception 'session snapshot.session.playerCount must match players length';
  end if;

  if p_snapshot->'session' ? 'courts' and v_courts < 0 then
    raise exception 'session snapshot.session.courts must be non-negative';
  end if;

  if p_snapshot->'session' ? 'courtNames'
     and jsonb_typeof(coalesce(p_snapshot->'session'->'courtNames', 'null'::jsonb)) <> 'array' then
    raise exception 'session snapshot.session.courtNames must be an array';
  end if;

  if p_snapshot->'session' ? 'courtTimes'
     and jsonb_typeof(coalesce(p_snapshot->'session'->'courtTimes', 'null'::jsonb)) <> 'array' then
    raise exception 'session snapshot.session.courtTimes must be an array';
  end if;

  if p_snapshot->'session' ? 'slotsPerCourt'
     and jsonb_typeof(coalesce(p_snapshot->'session'->'slotsPerCourt', 'null'::jsonb)) <> 'array' then
    raise exception 'session snapshot.session.slotsPerCourt must be an array';
  end if;

  if exists (
    select 1
    from jsonb_array_elements(coalesce(p_snapshot->'session'->'courtTimes', '[]'::jsonb)) as court_time(value)
    where jsonb_typeof(court_time.value) <> 'object'
       or coalesce(court_time.value->>'start', '') = ''
       or coalesce(court_time.value->>'end', '') = ''
       or (court_time.value->>'end')::time <= (court_time.value->>'start')::time
  ) then
    raise exception 'session courtTimes entries must contain valid ascending start/end times';
  end if;

  if exists (
    select 1
    from jsonb_array_elements_text(coalesce(p_snapshot->'session'->'slotsPerCourt', '[]'::jsonb)) as slot_count(value)
    where nullif(slot_count.value, '')::integer < 0
  ) then
    raise exception 'session slotsPerCourt values must be non-negative';
  end if;

  select count(*)
  into v_schedule_count
  from jsonb_array_elements(p_snapshot->'schedule') as schedule_item(value);

  if p_snapshot->'session' ? 'totalGames'
     and coalesce(nullif(p_snapshot->'session'->>'totalGames', '')::integer, -1) <> v_schedule_count then
    raise exception 'session snapshot.session.totalGames must match schedule length';
  end if;

  if exists (
    select 1
    from jsonb_array_elements(p_snapshot->'schedule') as schedule_item(value)
    where jsonb_typeof(schedule_item.value) <> 'object'
       or nullif(schedule_item.value->>'slot', '') is null
       or nullif(schedule_item.value->>'court', '') is null
       or (schedule_item.value->>'slot')::integer < 0
       or (schedule_item.value->>'court')::integer < 0
       or jsonb_typeof(coalesce(schedule_item.value->'teamA', 'null'::jsonb)) <> 'array'
       or jsonb_typeof(coalesce(schedule_item.value->'teamB', 'null'::jsonb)) <> 'array'
       or jsonb_array_length(schedule_item.value->'teamA') <> 2
       or jsonb_array_length(schedule_item.value->'teamB') <> 2
  ) then
    raise exception 'session schedule entries must have non-negative slot/court and 2 players per team';
  end if;

  if exists (
    select 1
    from (
      select
        (schedule_item.value->>'slot')::integer as slot_index,
        (schedule_item.value->>'court')::integer as court_index,
        count(*) as c
      from jsonb_array_elements(p_snapshot->'schedule') as schedule_item(value)
      group by 1, 2
      having count(*) > 1
    ) dup_game
  ) then
    raise exception 'session schedule must not repeat slot/court combinations';
  end if;

  if exists (
    select 1
    from (
      select trim(team_a.value) as player_ref
      from jsonb_array_elements(p_snapshot->'schedule') as schedule_item(value)
      cross join lateral jsonb_array_elements_text(schedule_item.value->'teamA') as team_a(value)

      union all

      select trim(team_b.value)
      from jsonb_array_elements(p_snapshot->'schedule') as schedule_item(value)
      cross join lateral jsonb_array_elements_text(schedule_item.value->'teamB') as team_b(value)
    ) scheduled_ref
    left join (
      select trim(player_item.value->>'id') as player_ref
      from jsonb_array_elements(p_snapshot->'players') as player_item(value)
    ) players
      on players.player_ref = scheduled_ref.player_ref
    where scheduled_ref.player_ref = ''
       or players.player_ref is null
  ) then
    raise exception 'session schedule must only reference known non-blank player ids';
  end if;

  if exists (
    select 1
    from jsonb_array_elements(p_snapshot->'schedule') as schedule_item(value)
    where (
      select count(*)
      from (
        select trim(team_a.value) as player_ref
        from jsonb_array_elements_text(schedule_item.value->'teamA') as team_a(value)
        union all
        select trim(team_b.value)
        from jsonb_array_elements_text(schedule_item.value->'teamB') as team_b(value)
      ) all_players
    ) <> (
      select count(distinct player_ref)
      from (
        select trim(team_a.value) as player_ref
        from jsonb_array_elements_text(schedule_item.value->'teamA') as team_a(value)
        union all
        select trim(team_b.value)
        from jsonb_array_elements_text(schedule_item.value->'teamB') as team_b(value)
      ) all_players
    )
  ) then
    raise exception 'session schedule entries must not repeat a player within the same game';
  end if;

  if exists (
    select 1
    from jsonb_array_elements(p_snapshot->'fixMatches') as fix_match_item(value)
    where jsonb_typeof(fix_match_item.value) <> 'object'
       or jsonb_typeof(coalesce(fix_match_item.value->'slots', 'null'::jsonb)) <> 'array'
       or jsonb_array_length(fix_match_item.value->'slots') > 4
  ) then
    raise exception 'session fixMatches entries must contain a slots array with at most 4 items';
  end if;

  if exists (
    select 1
    from (
      select coalesce(nullif(fix_match_item.value->>'id', ''), format('fix-%s', fix_match_item.ordinality - 1)) as legacy_ref, count(*) as c
      from jsonb_array_elements(p_snapshot->'fixMatches') with ordinality as fix_match_item(value, ordinality)
      group by 1
      having count(*) > 1
    ) dup_fix_match
  ) then
    raise exception 'session fixMatches ids must be unique';
  end if;

  if exists (
    select 1
    from (
      select nullif(trim(slot.value), '') as player_ref
      from jsonb_array_elements(p_snapshot->'fixMatches') as fix_match_item(value)
      cross join lateral jsonb_array_elements_text(coalesce(fix_match_item.value->'slots', '[]'::jsonb)) as slot(value)
    ) fix_ref
    left join (
      select trim(player_item.value->>'id') as player_ref
      from jsonb_array_elements(p_snapshot->'players') as player_item(value)
    ) players
      on players.player_ref = fix_ref.player_ref
    where fix_ref.player_ref is not null
      and players.player_ref is null
  ) then
    raise exception 'session fixMatches must only reference known player ids';
  end if;

  if exists (
    select 1
    from (
      select nullif(trim(absent_player.value), '') as player_ref
      from jsonb_array_elements_text(coalesce(p_snapshot->'absentPlayers', '[]'::jsonb)) as absent_player(value)
    ) absent_ref
    left join (
      select trim(player_item.value->>'id') as player_ref
      from jsonb_array_elements(p_snapshot->'players') as player_item(value)
    ) players
      on players.player_ref = absent_ref.player_ref
    where absent_ref.player_ref is null
       or players.player_ref is null
  ) then
    raise exception 'session absentPlayers must only reference known non-blank player ids';
  end if;

  if exists (
    select 1
    from (
      select player_ref, count(*) as c
      from (
        select nullif(trim(absent_player.value), '') as player_ref
        from jsonb_array_elements_text(coalesce(p_snapshot->'absentPlayers', '[]'::jsonb)) as absent_player(value)
      ) absent_ref
      group by player_ref
      having count(*) > 1
    ) dup_absent
  ) then
    raise exception 'session absentPlayers must not contain duplicates';
  end if;

  if exists (
    select 1
    from (
      select played_game.value as game_key
      from jsonb_array_elements_text(p_snapshot->'playedGames') as played_game(value)
    ) played_ref
    left join (
      select concat((schedule_item.value->>'slot')::integer, '-', (schedule_item.value->>'court')::integer) as game_key
      from jsonb_array_elements(p_snapshot->'schedule') as schedule_item(value)
    ) schedule_keys
      on schedule_keys.game_key = played_ref.game_key
    where schedule_keys.game_key is null
  ) then
    raise exception 'session playedGames must only reference scheduled games';
  end if;

  if exists (
    select 1
    from (
      select played_game.value as game_key, count(*) as c
      from jsonb_array_elements_text(p_snapshot->'playedGames') as played_game(value)
      group by played_game.value
      having count(*) > 1
    ) dup_played
  ) then
    raise exception 'session playedGames must not contain duplicates';
  end if;

  if exists (
    select 1
    from jsonb_array_elements(p_snapshot->'schedule') as schedule_item(value)
    where exists (
      select 1
      from jsonb_each(p_snapshot->'gameScores') as score_entry(key, value)
      where score_entry.key = concat((schedule_item.value->>'slot')::integer, '-', (schedule_item.value->>'court')::integer)
    )
      and not exists (
        select 1
        from jsonb_array_elements_text(p_snapshot->'playedGames') as played_game(value)
        where played_game.value = concat((schedule_item.value->>'slot')::integer, '-', (schedule_item.value->>'court')::integer)
      )
  ) then
    raise exception 'session gameScores must only exist for games listed in playedGames';
  end if;

  if exists (
    select 1
    from jsonb_each(p_snapshot->'gameScores') as score_entry(key, value)
    left join (
      select concat((schedule_item.value->>'slot')::integer, '-', (schedule_item.value->>'court')::integer) as game_key
      from jsonb_array_elements(p_snapshot->'schedule') as schedule_item(value)
    ) schedule_keys
      on schedule_keys.game_key = score_entry.key
    where schedule_keys.game_key is null
       or jsonb_typeof(score_entry.value) <> 'object'
       or nullif(score_entry.value->>'a', '') is null
       or nullif(score_entry.value->>'b', '') is null
       or (score_entry.value->>'a')::integer not between 0 and 99
       or (score_entry.value->>'b')::integer not between 0 and 99
       or (score_entry.value->>'a')::integer = (score_entry.value->>'b')::integer
  ) then
    raise exception 'session gameScores must reference scheduled games and contain valid non-tied scores';
  end if;
end;
$$;

grant execute on function bm.validate_session_snapshot(jsonb) to anon, authenticated, service_role;

-- ─────────────────────────────────────────────────────────────────────
-- bm.validate_tournament_snapshot
-- Source: 000034 (20260618_000034_bm_tournament_snapshot_validation_fix.sql)
-- ─────────────────────────────────────────────────────────────────────
create or replace function bm.validate_tournament_snapshot(p_snapshot jsonb)
returns void
language plpgsql
security definer
set search_path = bm, public
as $$
declare
  v_pair_count integer;
  v_group_count integer;
  v_match_count integer;
  v_group_match_count integer;
  v_qf_count integer;
  v_sf_count integer;
  v_third_count integer;
  v_final_count integer;
begin
  if p_snapshot is null then
    raise exception 'tournament snapshot must not be null';
  end if;

  if jsonb_typeof(p_snapshot) <> 'object' then
    raise exception 'tournament snapshot must be a json object';
  end if;

  if trim(coalesce(p_snapshot->>'name', '')) = '' then
    raise exception 'tournament snapshot name must not be blank';
  end if;

  if coalesce(p_snapshot->>'date', '') = '' then
    raise exception 'tournament snapshot date must not be blank';
  end if;

  perform (p_snapshot->>'date')::date;

  if jsonb_typeof(coalesce(p_snapshot->'pairs', 'null'::jsonb)) <> 'array' then
    raise exception 'tournament snapshot pairs must be an array';
  end if;

  if jsonb_typeof(coalesce(p_snapshot->'groups', 'null'::jsonb)) <> 'object' then
    raise exception 'tournament snapshot groups must be an object';
  end if;

  if jsonb_typeof(coalesce(p_snapshot->'matches', 'null'::jsonb)) <> 'array' then
    raise exception 'tournament snapshot matches must be an array';
  end if;

  select count(*)
  into v_pair_count
  from jsonb_array_elements(p_snapshot->'pairs') as pair_item(value);

  if v_pair_count <> 16 then
    raise exception 'tournament snapshot must contain exactly 16 pairs';
  end if;

  if exists (
    select 1
    from jsonb_array_elements(p_snapshot->'pairs') as pair_item(value)
    where jsonb_typeof(pair_item.value) <> 'object'
       or trim(coalesce(pair_item.value->>'id', '')) = ''
       or trim(coalesce(pair_item.value->>'name', '')) = ''
  ) then
    raise exception 'tournament pairs must contain non-blank id and name fields';
  end if;

  if exists (
    select 1
    from (
      select pair_item.value->>'id' as pair_id, count(*) as c
      from jsonb_array_elements(p_snapshot->'pairs') as pair_item(value)
      group by pair_item.value->>'id'
      having count(*) > 1
    ) dup_pair
  ) then
    raise exception 'tournament pair ids must be unique';
  end if;

  select count(*)
  into v_group_count
  from jsonb_object_keys(p_snapshot->'groups') as group_key(value);

  if v_group_count <> 4 then
    raise exception 'tournament groups must contain exactly 4 keys';
  end if;

  if exists (
    select 1
    from (values ('A'), ('B'), ('C'), ('D')) as expected(group_id)
    where not ((p_snapshot->'groups') ? expected.group_id)
  ) then
    raise exception 'tournament groups must contain keys A, B, C, and D';
  end if;

  if exists (
    select 1
    from (values ('A'), ('B'), ('C'), ('D')) as expected(group_id)
    where jsonb_typeof(p_snapshot->'groups'->expected.group_id) <> 'array'
  ) then
    raise exception 'each tournament group must be an array';
  end if;

  if exists (
    select 1
    from (values ('A'), ('B'), ('C'), ('D')) as expected(group_id)
    where jsonb_array_length(p_snapshot->'groups'->expected.group_id) not in (0, 4)
  ) then
    raise exception 'each tournament group must contain either 0 or 4 pair ids';
  end if;

  if exists (
    select 1
    from (
      select jsonb_array_elements_text(p_snapshot->'groups'->'A') as pair_id
      union all
      select jsonb_array_elements_text(p_snapshot->'groups'->'B')
      union all
      select jsonb_array_elements_text(p_snapshot->'groups'->'C')
      union all
      select jsonb_array_elements_text(p_snapshot->'groups'->'D')
    ) grouped
    left join (
      select pair_item.value->>'id' as pair_id
      from jsonb_array_elements(p_snapshot->'pairs') as pair_item(value)
    ) pairs
      on pairs.pair_id = grouped.pair_id
    where trim(coalesce(grouped.pair_id, '')) = ''
       or pairs.pair_id is null
  ) then
    raise exception 'tournament groups must only reference known non-blank pair ids';
  end if;

  if exists (
    select 1
    from (
      select pair_id, count(*) as c
      from (
        select jsonb_array_elements_text(p_snapshot->'groups'->'A') as pair_id
        union all
        select jsonb_array_elements_text(p_snapshot->'groups'->'B')
        union all
        select jsonb_array_elements_text(p_snapshot->'groups'->'C')
        union all
        select jsonb_array_elements_text(p_snapshot->'groups'->'D')
      ) grouped
      group by pair_id
      having count(*) > 1
    ) dup_group_pair
  ) then
    raise exception 'tournament group assignments must not repeat pair ids';
  end if;

  select
    count(*)::integer,
    count(*) filter (where match_item.value->>'phase' = 'group')::integer,
    count(*) filter (where match_item.value->>'phase' = 'qf')::integer,
    count(*) filter (where match_item.value->>'phase' = 'sf')::integer,
    count(*) filter (where match_item.value->>'phase' = '3rd')::integer,
    count(*) filter (where match_item.value->>'phase' = 'final')::integer
  into
    v_match_count,
    v_group_match_count,
    v_qf_count,
    v_sf_count,
    v_third_count,
    v_final_count
  from jsonb_array_elements(p_snapshot->'matches') as match_item(value);

  if v_match_count <> 32 then
    raise exception 'tournament snapshot must contain exactly 32 matches';
  end if;

  if v_group_match_count <> 24 or v_qf_count <> 4 or v_sf_count <> 2 or v_third_count <> 1 or v_final_count <> 1 then
    raise exception 'tournament snapshot must contain 24 group matches, 4 qf, 2 sf, 1 third-place, and 1 final';
  end if;

  if exists (
    select 1
    from jsonb_array_elements(p_snapshot->'matches') as match_item(value)
    where jsonb_typeof(match_item.value) <> 'object'
       or trim(coalesce(match_item.value->>'id', '')) = ''
       or coalesce(match_item.value->>'phase', '') not in ('group', 'qf', 'sf', '3rd', 'final')
  ) then
    raise exception 'tournament matches must contain non-blank id and valid phase fields';
  end if;

  if exists (
    select 1
    from (
      select match_item.value->>'id' as match_id, count(*) as c
      from jsonb_array_elements(p_snapshot->'matches') as match_item(value)
      group by match_item.value->>'id'
      having count(*) > 1
    ) dup_match
  ) then
    raise exception 'tournament match ids must be unique';
  end if;

  if exists (
    select 1
    from (
      select
        trim(coalesce(match_item.value->>'pairAId', '')) as pair_a_id,
        trim(coalesce(match_item.value->>'pairBId', '')) as pair_b_id
      from jsonb_array_elements(p_snapshot->'matches') as match_item(value)
    ) match_pairs
    left join (
      select pair_item.value->>'id' as pair_id
      from jsonb_array_elements(p_snapshot->'pairs') as pair_item(value)
    ) pairs_a
      on pairs_a.pair_id = match_pairs.pair_a_id
    left join (
      select pair_item.value->>'id' as pair_id
      from jsonb_array_elements(p_snapshot->'pairs') as pair_item(value)
    ) pairs_b
      on pairs_b.pair_id = match_pairs.pair_b_id
    where (match_pairs.pair_a_id <> '' and pairs_a.pair_id is null)
       or (match_pairs.pair_b_id <> '' and pairs_b.pair_id is null)
       or (match_pairs.pair_a_id <> '' and match_pairs.pair_b_id <> '' and match_pairs.pair_a_id = match_pairs.pair_b_id)
  ) then
    raise exception 'tournament matches must reference known distinct pair ids';
  end if;
end;
$$;

grant execute on function bm.validate_tournament_snapshot(jsonb) to anon, authenticated, service_role;

-- ─────────────────────────────────────────────────────────────────────
-- bm.resolve_session_lookup
-- Source: 000015 (20260618_000015_bm_uuid_first_phase_a_batch_1.sql)
-- ─────────────────────────────────────────────────────────────────────
create or replace function bm.resolve_session_lookup(p_lookup text)
returns table (
  session_id text,
  session_share_id text,
  session_internal_id uuid
)
language sql
security definer
set search_path = bm, public
as $$
  select
    s.id,
    s.share_id,
    s.internal_id
  from bm.sessions s
  where s.id = trim(coalesce(p_lookup, ''))
     or s.share_id = trim(coalesce(p_lookup, ''))
     or s.internal_id::text = trim(coalesce(p_lookup, ''))
  order by
    (s.id = trim(coalesce(p_lookup, ''))) desc,
    (s.share_id = trim(coalesce(p_lookup, ''))) desc
  limit 1;
$$;

grant execute on function bm.resolve_session_lookup(text) to anon, authenticated, service_role;

-- ─────────────────────────────────────────────────────────────────────
-- bm.resolve_tournament_lookup
-- Source: 000015 (20260618_000015_bm_uuid_first_phase_a_batch_1.sql)
-- ─────────────────────────────────────────────────────────────────────
create or replace function bm.resolve_tournament_lookup(p_lookup text)
returns table (
  tournament_id text,
  tournament_share_id text,
  tournament_internal_id uuid
)
language sql
security definer
set search_path = bm, public
as $$
  select
    t.id,
    t.share_id,
    t.internal_id
  from bm.tournaments t
  where t.id = trim(coalesce(p_lookup, ''))
     or t.share_id = trim(coalesce(p_lookup, ''))
     or t.internal_id::text = trim(coalesce(p_lookup, ''))
  order by
    (t.id = trim(coalesce(p_lookup, ''))) desc,
    (t.share_id = trim(coalesce(p_lookup, ''))) desc
  limit 1;
$$;

grant execute on function bm.resolve_tournament_lookup(text) to anon, authenticated, service_role;

-- ─────────────────────────────────────────────────────────────────────
-- bm.get_session_snapshot_compat
-- Source: 000020 (20260618_000020_bm_phase_b_internal_id_adoption.sql)
-- ─────────────────────────────────────────────────────────────────────
create or replace function bm.get_session_snapshot_compat(p_id text)
returns jsonb
language sql
security definer
set search_path = bm, public
as $$
  with resolved as (
    select
      r.session_id,
      r.session_internal_id
    from bm.resolve_session_lookup(p_id) r
  ),
  target_session as (
    select s.*
    from bm.sessions s
    join resolved r
      on r.session_internal_id = s.internal_id
  ),
  court_rows as (
    select
      sc.session_id,
      sc.session_internal_id,
      sc.court_index,
      sc.court_name,
      sc.start_time,
      sc.end_time,
      coalesce(game_counts.game_count, 0) as game_count
    from bm.session_courts sc
    join resolved r
      on r.session_internal_id = sc.session_internal_id
    left join (
      select
        sg.session_internal_id,
        sg.court_index,
        count(*)::integer as game_count
      from bm.scheduled_games sg
      group by sg.session_internal_id, sg.court_index
    ) game_counts
      on game_counts.session_internal_id = sc.session_internal_id
     and game_counts.court_index = sc.court_index
  ),
  player_rows as (
    select
      sp.session_id,
      sp.session_internal_id,
      sp.sort_order,
      sp.absent_order,
      sp.player_ref,
      sp.source_name,
      sp.gender,
      sp.tier,
      sp.is_absent,
      sp.internal_id
    from bm.session_players sp
    join resolved r
      on r.session_internal_id = sp.session_internal_id
  ),
  fix_match_rows as (
    select
      fm.session_id,
      fm.session_internal_id,
      fm.sort_order,
      fm.legacy_ref,
      fm.internal_id,
      (
        select jsonb_agg(coalesce(sp.player_ref, '') order by fms.slot_index)
        from bm.fix_match_slots fms
        left join player_rows sp
          on sp.internal_id = fms.session_player_internal_id
        where fms.fix_match_internal_id = fm.internal_id
      ) as slots_json
    from bm.fix_matches fm
    join resolved r
      on r.session_internal_id = fm.session_internal_id
  ),
  game_rows as (
    select
      sg.session_id,
      sg.session_internal_id,
      sg.legacy_order,
      sg.slot_index,
      sg.court_index,
      sg.internal_id,
      gp.is_played,
      gp.played_order,
      gs.score_a,
      gs.score_b,
      (
        select jsonb_agg(sp.player_ref order by sgp.position)
        from bm.scheduled_game_players sgp
        join player_rows sp
          on sp.internal_id = sgp.session_player_internal_id
        where sgp.scheduled_game_internal_id = sg.internal_id
          and sgp.team = 'A'
      ) as team_a_json,
      (
        select jsonb_agg(sp.player_ref order by sgp.position)
        from bm.scheduled_game_players sgp
        join player_rows sp
          on sp.internal_id = sgp.session_player_internal_id
        where sgp.scheduled_game_internal_id = sg.internal_id
          and sgp.team = 'B'
      ) as team_b_json
    from bm.scheduled_games sg
    join resolved r
      on r.session_internal_id = sg.session_internal_id
    left join bm.game_progress gp
      on gp.scheduled_game_internal_id = sg.internal_id
    left join bm.game_scores gs
      on gs.scheduled_game_internal_id = sg.internal_id
  )
  select
    case
      when exists (select 1 from target_session) then
        jsonb_build_object(
          'session', jsonb_build_object(
            'title', coalesce((select ts.title from target_session ts), ''),
            'date', (select ts.session_date::text from target_session ts),
            'courts', coalesce((select count(*)::integer from court_rows), 0),
            'sessionStart', coalesce((select to_char(ts.session_start, 'HH24:MI') from target_session ts), '00:00'),
            'slotMinutes', coalesce((select ts.slot_minutes from target_session ts), 20),
            'courtTimes', coalesce((
              select jsonb_agg(
                jsonb_build_object(
                  'start', to_char(cr.start_time, 'HH24:MI'),
                  'end', to_char(cr.end_time, 'HH24:MI')
                )
                order by cr.court_index
              )
              from court_rows cr
            ), '[]'::jsonb),
            'playerCount', coalesce((select count(*)::integer from player_rows), 0),
            'slotsPerCourt', coalesce((
              select jsonb_agg(cr.game_count order by cr.court_index)
              from court_rows cr
            ), '[]'::jsonb),
            'totalGames', coalesce((select count(*)::integer from game_rows), 0),
            'courtNames', case
              when exists (
                select 1
                from court_rows cr
                where cr.court_name <> ''
              ) then coalesce((
                select jsonb_agg(cr.court_name order by cr.court_index)
                from court_rows cr
              ), '[]'::jsonb)
              else '[]'::jsonb
            end,
            'locked', coalesce((select ts.status <> 'draft' from target_session ts), false)
          )
          ||
          case
            when coalesce((select ts.include_tier_count from target_session ts), false) then
              jsonb_build_object(
                'tierCount',
                coalesce((select ts.session_tier_count from target_session ts), 0)
              )
            else '{}'::jsonb
          end,
          'players', coalesce((
            select jsonb_agg(
              jsonb_build_object(
                'name', pr.source_name,
                'gender', pr.gender,
                'tier', pr.tier,
                'id', pr.player_ref
              )
              order by pr.sort_order
            )
            from player_rows pr
          ), '[]'::jsonb),
          'fixMatches', coalesce((
            select jsonb_agg(
              jsonb_build_object(
                'slots', coalesce(fmr.slots_json, '[]'::jsonb),
                'id', fmr.legacy_ref
              )
              order by fmr.sort_order
            )
            from fix_match_rows fmr
          ), '[]'::jsonb),
          'schedule', coalesce((
            select jsonb_agg(
              jsonb_build_object(
                'slot', gr.slot_index,
                'court', gr.court_index,
                'teamA', coalesce(gr.team_a_json, '[]'::jsonb),
                'teamB', coalesce(gr.team_b_json, '[]'::jsonb)
              )
              order by gr.legacy_order
            )
            from game_rows gr
          ), '[]'::jsonb),
          'playedGames', coalesce((
            select jsonb_agg(
              to_jsonb(concat(gr.slot_index, '-', gr.court_index))
              order by gr.played_order
            )
            from game_rows gr
            where coalesce(gr.is_played, false)
              and gr.played_order is not null
          ), '[]'::jsonb),
          'gameScores', coalesce((
            select jsonb_object_agg(
              concat(gr.slot_index, '-', gr.court_index),
              jsonb_build_object('a', gr.score_a, 'b', gr.score_b)
            )
            from game_rows gr
            where gr.score_a is not null
              and gr.score_b is not null
          ), '{}'::jsonb)
          )
        ||
        case
          when coalesce((select ts.include_absent_players from target_session ts), false) then
            jsonb_build_object(
              'absentPlayers',
              coalesce((
                select jsonb_agg(to_jsonb(pr.player_ref) order by pr.absent_order, pr.sort_order)
                from player_rows pr
                where pr.is_absent
              ), '[]'::jsonb)
            )
          else '{}'::jsonb
        end
      else null
    end;
$$;

grant execute on function bm.get_session_snapshot_compat(text) to anon, authenticated, service_role;

-- ─────────────────────────────────────────────────────────────────────
-- bm.get_session
-- Source: 000015 (20260618_000015_bm_uuid_first_phase_a_batch_1.sql)
-- ─────────────────────────────────────────────────────────────────────
create or replace function bm.get_session(p_id text)
returns jsonb
language sql
security definer
set search_path = bm, public
as $$
  with resolved as (
    select session_id
    from bm.resolve_session_lookup(p_id)
  )
  select bm.get_session_snapshot_compat(resolved.session_id) || jsonb_build_object('version', s.version)
  from resolved
  join bm.sessions s
    on s.id = resolved.session_id;
$$;

grant execute on function bm.get_session(text) to anon, authenticated, service_role;

-- ─────────────────────────────────────────────────────────────────────
-- bm.list_sessions
-- Source: 000048 (20260714_000048_bm_list_sessions_lock_status.sql)
-- ─────────────────────────────────────────────────────────────────────
create or replace function bm.list_sessions()
returns table (
  id text,
  title text,
  date text,
  player_count integer,
  total_games integer,
  locked boolean
)
language sql
security definer
set search_path = bm, public
as $$
  select
    s.id,
    s.title,
    s.session_date::text as date,
    coalesce(player_counts.player_count, 0) as player_count,
    coalesce(game_counts.total_games, 0) as total_games,
    (s.status <> 'draft') as locked
  from bm.sessions s
  left join (
    select
      sp.session_internal_id,
      count(*)::integer as player_count
    from bm.session_players sp
    group by sp.session_internal_id
  ) player_counts
    on player_counts.session_internal_id = s.internal_id
  left join (
    select
      sg.session_internal_id,
      count(*)::integer as total_games
    from bm.scheduled_games sg
    group by sg.session_internal_id
  ) game_counts
    on game_counts.session_internal_id = s.internal_id
  order by s.session_date desc, s.updated_at desc;
$$;

grant execute on function bm.list_sessions() to anon, authenticated, service_role;

-- ─────────────────────────────────────────────────────────────────────
-- bm.list_players
-- Source: 000028 (20260618_000028_bm_runtime_regression_fix.sql)
-- ─────────────────────────────────────────────────────────────────────
create or replace function bm.list_players()
returns table (
  name text,
  gender text,
  tier integer
)
language sql
security definer
set search_path = bm, public
as $$
  with ranked_appearances as (
    select
      p.id as player_id,
      p.canonical_name,
      sp.gender,
      sp.tier,
      row_number() over (
        partition by p.id
        order by s.session_date desc, sp.updated_at desc, sp.internal_id desc
      ) as rn
    from bm.players p
    join bm.session_players sp
      on sp.player_id = p.id
    join bm.sessions s
      on s.internal_id = sp.session_internal_id
  )
  select
    ra.canonical_name as name,
    ra.gender,
    ra.tier
  from ranked_appearances ra
  where ra.rn = 1
  order by lower(ra.canonical_name);
$$;

grant execute on function bm.list_players() to anon, authenticated, service_role;

-- ─────────────────────────────────────────────────────────────────────
-- bm.get_player_stats_compat
-- Source: 000033 (20260618_000033_bm_reapply_player_stats_uuid_only.sql)
-- ─────────────────────────────────────────────────────────────────────
create or replace function bm.get_player_stats_compat(p_name text)
returns jsonb
language plpgsql
security definer
set search_path = bm, public
as $$
declare
  v_player_id uuid;
  v_resolved_name text := p_name;
  v_games_played integer := 0;
  v_wins integer := 0;
  v_losses integer := 0;
  v_points_for integer := 0;
  v_points_against integer := 0;
  v_sessions jsonb := '[]'::jsonb;
  v_top_partners jsonb := '[]'::jsonb;
  v_top_opponents jsonb := '[]'::jsonb;
begin
  select
    p.id,
    p.canonical_name
  into
    v_player_id,
    v_resolved_name
  from bm.player_aliases pa
  join bm.players p
    on p.id = pa.player_id
  where pa.alias_name = bm.normalize_player_name(p_name)
  limit 1;

  if v_player_id is null then
    return jsonb_build_object(
      'name', p_name,
      'gamesPlayed', 0,
      'wins', 0,
      'losses', 0,
      'pointsFor', 0,
      'pointsAgainst', 0,
      'sessions', '[]'::jsonb,
      'topPartners', '[]'::jsonb,
      'topOpponents', '[]'::jsonb
    );
  end if;

  with target_memberships as (
    select
      sp.internal_id as session_player_internal_id,
      sp.session_id,
      sp.session_internal_id,
      sp.is_absent
    from bm.session_players sp
    where sp.player_id = v_player_id
  ),
  session_rows as (
    select
      tm.session_id as id,
      s.session_date::text as date,
      s.title,
      tm.is_absent as absent
    from target_memberships tm
    join bm.sessions s
      on s.internal_id = tm.session_internal_id
  ),
  player_games as (
    select
      tm.session_id,
      tm.session_internal_id,
      tm.session_player_internal_id,
      sg.internal_id as scheduled_game_internal_id,
      sgp.team as player_team,
      gs.score_a,
      gs.score_b
    from target_memberships tm
    join bm.scheduled_game_players sgp
      on sgp.session_player_internal_id = tm.session_player_internal_id
    join bm.scheduled_games sg
      on sg.internal_id = sgp.scheduled_game_internal_id
     and sg.session_internal_id = tm.session_internal_id
    left join bm.game_scores gs
      on gs.scheduled_game_internal_id = sg.internal_id
  ),
  base_stats as (
    select
      count(*)::integer as games_played,
      coalesce(sum(case
        when pg.score_a is null or pg.score_b is null then 0
        when pg.player_team = 'A' and pg.score_a > pg.score_b then 1
        when pg.player_team = 'B' and pg.score_b > pg.score_a then 1
        else 0
      end), 0)::integer as wins,
      coalesce(sum(case
        when pg.score_a is null or pg.score_b is null then 0
        when pg.player_team = 'A' and pg.score_a < pg.score_b then 1
        when pg.player_team = 'B' and pg.score_b < pg.score_a then 1
        else 0
      end), 0)::integer as losses,
      coalesce(sum(case
        when pg.score_a is null or pg.score_b is null then 0
        when pg.player_team = 'A' then pg.score_a
        else pg.score_b
      end), 0)::integer as points_for,
      coalesce(sum(case
        when pg.score_a is null or pg.score_b is null then 0
        when pg.player_team = 'A' then pg.score_b
        else pg.score_a
      end), 0)::integer as points_against
    from player_games pg
  ),
  partner_rows as (
    select
      partner.canonical_name as partner_name,
      count(*)::integer as count,
      coalesce(sum(case
        when pg.score_a is null or pg.score_b is null then 0
        when pg.player_team = 'A' and pg.score_a > pg.score_b then 1
        when pg.player_team = 'B' and pg.score_b > pg.score_a then 1
        else 0
      end), 0)::integer as wins,
      coalesce(sum(case
        when pg.score_a is null or pg.score_b is null then 0
        when pg.player_team = 'A' and pg.score_a < pg.score_b then 1
        when pg.player_team = 'B' and pg.score_b < pg.score_a then 1
        else 0
      end), 0)::integer as losses
    from player_games pg
    join bm.scheduled_game_players teammate_link
      on teammate_link.scheduled_game_internal_id = pg.scheduled_game_internal_id
     and teammate_link.team = pg.player_team
     and teammate_link.session_player_internal_id <> pg.session_player_internal_id
    join bm.session_players teammate_sp
      on teammate_sp.internal_id = teammate_link.session_player_internal_id
     and teammate_sp.session_internal_id = pg.session_internal_id
    join bm.players partner
      on partner.id = teammate_sp.player_id
    group by partner.canonical_name
    order by count desc, lower(partner.canonical_name)
    limit 5
  ),
  opponent_rows as (
    select
      opponent.canonical_name as opponent_name,
      count(*)::integer as count,
      coalesce(sum(case
        when pg.score_a is null or pg.score_b is null then 0
        when pg.player_team = 'A' and pg.score_a > pg.score_b then 1
        when pg.player_team = 'B' and pg.score_b > pg.score_a then 1
        else 0
      end), 0)::integer as wins,
      coalesce(sum(case
        when pg.score_a is null or pg.score_b is null then 0
        when pg.player_team = 'A' and pg.score_a < pg.score_b then 1
        when pg.player_team = 'B' and pg.score_b < pg.score_a then 1
        else 0
      end), 0)::integer as losses
    from player_games pg
    join bm.scheduled_game_players opponent_link
      on opponent_link.scheduled_game_internal_id = pg.scheduled_game_internal_id
     and opponent_link.team <> pg.player_team
    join bm.session_players opponent_sp
      on opponent_sp.internal_id = opponent_link.session_player_internal_id
     and opponent_sp.session_internal_id = pg.session_internal_id
    join bm.players opponent
      on opponent.id = opponent_sp.player_id
    group by opponent.canonical_name
    order by count desc, lower(opponent.canonical_name)
    limit 5
  )
  select
    coalesce((select bs.games_played from base_stats bs), 0),
    coalesce((select bs.wins from base_stats bs), 0),
    coalesce((select bs.losses from base_stats bs), 0),
    coalesce((select bs.points_for from base_stats bs), 0),
    coalesce((select bs.points_against from base_stats bs), 0),
    coalesce((select jsonb_agg(to_jsonb(sr) order by sr.date desc) from session_rows sr), '[]'::jsonb),
    coalesce((select jsonb_agg(jsonb_build_object(
      'name', pr.partner_name,
      'count', pr.count,
      'wins', pr.wins,
      'losses', pr.losses
    )) from partner_rows pr), '[]'::jsonb),
    coalesce((select jsonb_agg(jsonb_build_object(
      'name', orow.opponent_name,
      'count', orow.count,
      'wins', orow.wins,
      'losses', orow.losses
    )) from opponent_rows orow), '[]'::jsonb)
  into
    v_games_played,
    v_wins,
    v_losses,
    v_points_for,
    v_points_against,
    v_sessions,
    v_top_partners,
    v_top_opponents;

  return jsonb_build_object(
    'name', v_resolved_name,
    'gamesPlayed', v_games_played,
    'wins', v_wins,
    'losses', v_losses,
    'pointsFor', v_points_for,
    'pointsAgainst', v_points_against,
    'sessions', v_sessions,
    'topPartners', v_top_partners,
    'topOpponents', v_top_opponents
  );
end;
$$;

grant execute on function bm.get_player_stats_compat(text) to anon, authenticated, service_role;

-- ─────────────────────────────────────────────────────────────────────
-- bm.get_player_stats
-- Source: 000033 (20260618_000033_bm_reapply_player_stats_uuid_only.sql)
-- ─────────────────────────────────────────────────────────────────────
create or replace function bm.get_player_stats(p_name text)
returns jsonb
language sql
security definer
set search_path = bm, public
as $$
  select bm.get_player_stats_compat(p_name);
$$;

grant execute on function bm.get_player_stats(text) to anon, authenticated, service_role;

-- ─────────────────────────────────────────────────────────────────────
-- bm.get_tournament
-- Source: 000015 (20260618_000015_bm_uuid_first_phase_a_batch_1.sql)
-- ─────────────────────────────────────────────────────────────────────
create or replace function bm.get_tournament(p_id text)
returns jsonb
language sql
security definer
set search_path = bm, public
as $$
  with resolved as (
    select tournament_id
    from bm.resolve_tournament_lookup(p_id)
  )
  select t.snapshot || jsonb_build_object('version', t.version)
  from resolved
  join bm.tournaments t
    on t.id = resolved.tournament_id;
$$;

grant execute on function bm.get_tournament(text) to anon, authenticated, service_role;

-- ─────────────────────────────────────────────────────────────────────
-- bm.register_player
-- Source: 000052 (20260714_000052_bm_fix_register_player_toctou.sql)
-- ─────────────────────────────────────────────────────────────────────
create or replace function bm.register_player(
  p_name text,
  p_canonical_name text default null
)
returns uuid
language plpgsql
security definer
set search_path = bm, public
as $$
declare
  v_alias_name text := bm.normalize_player_name(p_name);
  v_canonical_input text := coalesce(nullif(trim(coalesce(p_canonical_name, '')), ''), p_name);
  v_canonical_norm text := bm.normalize_player_name(v_canonical_input);
  v_player_id uuid;
begin
  if v_alias_name is null then
    raise exception 'player name must not be blank';
  end if;

  -- If alias already exists, return the existing player (idempotent)
  select player_id into v_player_id
  from bm.player_aliases
  where alias_name = v_alias_name;

  if found then
    return v_player_id;
  end if;

  -- When canonical name provided (merge case), try to resolve existing
  -- player via normalized alias lookup. This finds "Fredi" even if the
  -- caller passes "fredi", "FREDI", " Fredi ", etc.
  if v_canonical_norm is not null then
    select pa.player_id into v_player_id
    from bm.player_aliases pa
    where pa.alias_name = v_canonical_norm;
  end if;

  -- If not resolved, create new player with ORIGINAL case preserved
  if v_player_id is null then
    v_player_id := bm.ensure_player(v_canonical_input);
  end if;

  -- Register the alias (normalized for case-insensitive matching)
  insert into bm.player_aliases (alias_name, player_id)
  values (v_alias_name, v_player_id)
  on conflict (alias_name) do nothing;

  -- Re-query to get the actual alias owner (handles race condition).
  -- If a concurrent request won the INSERT race, this returns THEIR
  -- player_id instead of our stale local value.
  select pa.player_id into v_player_id
  from bm.player_aliases pa
  where pa.alias_name = v_alias_name;

  return v_player_id;
end;
$$;

grant execute on function bm.register_player(text, text) to anon, authenticated, service_role;

-- ─────────────────────────────────────────────────────────────────────
-- bm.publish_session
-- Source: 000050 (20260714_000050_bm_publish_unlock_rpc_fixes.sql)
-- ─────────────────────────────────────────────────────────────────────
create or replace function bm.publish_session(
  p_id text,
  p_snapshot jsonb,
  p_source text default 'compat_publish'
)
returns jsonb
language plpgsql
security definer
set search_path = bm, public
as $$
declare
  v_lookup text := trim(coalesce(p_id, ''));
  v_id text := v_lookup;
  v_share_id text := v_lookup;
  v_internal_id uuid := gen_random_uuid();
  v_session_found boolean;
  v_title text := coalesce(p_snapshot->'session'->>'title', '');
  v_session_date date := coalesce(nullif(p_snapshot->'session'->>'date', '')::date, current_date);
  v_session_start time := coalesce(nullif(p_snapshot->'session'->>'sessionStart', '')::time, '00:00'::time);
  v_slot_minutes integer := coalesce(nullif(p_snapshot->'session'->>'slotMinutes', '')::integer, 20);
  v_session_tier_count integer := coalesce(nullif(p_snapshot->'session'->>'tierCount', '')::integer, 0);
  v_include_tier_count boolean := coalesce((p_snapshot->'session') ? 'tierCount', false);
  v_include_absent_players boolean := p_snapshot ? 'absentPlayers';
  v_is_locked boolean := coalesce((p_snapshot->'session'->>'locked')::boolean, false);
  v_status text := case
    when v_is_locked then 'locked'
    else 'draft'
  end;
  v_unresolved jsonb := '[]'::jsonb;
  v_duplicate_resolution jsonb := '[]'::jsonb;
  v_invalid_refs jsonb := '[]'::jsonb;
  v_expected_version integer := nullif(p_snapshot->>'version', '')::integer;
  v_current_version integer;
  v_next_version integer := 1;
  v_current_status text;
begin
  if v_lookup = '' then
    raise exception 'session id must not be blank';
  end if;

  -- M3: Advisory lock BEFORE validation for fast rejection on contention.
  if not pg_try_advisory_xact_lock(hashtextextended(format('bm.publish_session:%s', v_lookup), 0)) then
    raise exception 'session is being updated by another request; reload and retry';
  end if;

  begin
    select s.id, s.share_id, s.internal_id, s.version, s.status
    into v_id, v_share_id, v_internal_id, v_current_version, v_current_status
    from bm.sessions s
    where s.id = v_lookup
       or s.share_id = v_lookup
       or s.internal_id::text = v_lookup
    order by
      (s.id = v_lookup) desc,
      (s.share_id = v_lookup) desc
    for update nowait;
  exception
    when lock_not_available then
      raise exception 'session is being updated by another request; reload and retry';
  end;

  -- Capture found BEFORE any subsequent SELECT...INTO overwrites it.
  v_session_found := found;

  if not v_session_found then
    v_id := v_lookup;
    v_share_id := v_lookup;
    v_internal_id := gen_random_uuid();
  end if;

  if v_session_found then
    -- H1: Reject writes for ANY non-draft status (locked, completed, archived).
    if v_current_status <> 'draft' then
      raise exception 'session is locked and cannot be modified';
    end if;

    if v_expected_version is not null and v_expected_version <> v_current_version then
      raise exception 'session version mismatch: expected %, actual %', v_expected_version, v_current_version;
    end if;

    v_next_version := v_current_version + 1;

  elsif v_expected_version is not null then
    raise exception 'session version mismatch: expected %, actual null', v_expected_version;
  end if;

  -- M3: Expensive validation runs AFTER the lock check above.
  perform bm.validate_session_snapshot(p_snapshot);

  if p_source not in ('compat_publish', 'legacy_snapshot', 'manual') then
    raise exception 'unsupported bm session source: %', p_source;
  end if;

  if v_slot_minutes <= 0 then
    raise exception 'slotMinutes must be positive for session %', v_lookup;
  end if;

  with snapshot_players as (
    select
      trim(player.value->>'id') as player_ref,
      coalesce(player.value->>'name', '') as source_name,
      bm.normalize_player_name(player.value->>'name') as normalized_name
    from jsonb_array_elements(coalesce(p_snapshot->'players', '[]'::jsonb)) with ordinality as player(value, ordinality)
  )
  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'sourceName', unresolved.source_name,
        'normalizedName', unresolved.normalized_name
      )
      order by unresolved.source_name
    ),
    '[]'::jsonb
  )
  into v_unresolved
  from (
    select sp.source_name, sp.normalized_name
    from snapshot_players sp
    left join bm.player_aliases pa
      on pa.alias_name = sp.normalized_name
    where sp.normalized_name is null
       or pa.player_id is null
  ) unresolved;

  if v_unresolved <> '[]'::jsonb then
    raise exception 'bm.publish_session unresolved players for session %: %', v_lookup, v_unresolved::text;
  end if;

  with snapshot_players as (
    select
      trim(player.value->>'id') as player_ref,
      coalesce(player.value->>'name', '') as source_name,
      bm.normalize_player_name(player.value->>'name') as normalized_name
    from jsonb_array_elements(coalesce(p_snapshot->'players', '[]'::jsonb)) with ordinality as player(value, ordinality)
  ),
  resolved_players as (
    select sp.player_ref, sp.source_name, pa.player_id
    from snapshot_players sp
    join bm.player_aliases pa
      on pa.alias_name = sp.normalized_name
  )
  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'playerRef', duplicates.player_ref,
        'sourceNames', duplicates.source_names
      )
      order by duplicates.player_ref
    ),
    '[]'::jsonb
  )
  into v_invalid_refs
  from (
    select
      rp.player_ref,
      jsonb_agg(rp.source_name order by rp.source_name) as source_names
    from resolved_players rp
    where rp.player_ref = ''
    group by rp.player_ref
  ) duplicates;

  if v_invalid_refs <> '[]'::jsonb then
    raise exception 'bm.publish_session invalid player refs for session %: %', v_lookup, v_invalid_refs::text;
  end if;

  with snapshot_players as (
    select
      trim(player.value->>'id') as player_ref,
      coalesce(player.value->>'name', '') as source_name,
      bm.normalize_player_name(player.value->>'name') as normalized_name
    from jsonb_array_elements(coalesce(p_snapshot->'players', '[]'::jsonb)) with ordinality as player(value, ordinality)
  ),
  resolved_players as (
    select sp.player_ref, sp.source_name, pa.player_id
    from snapshot_players sp
    join bm.player_aliases pa
      on pa.alias_name = sp.normalized_name
  )
  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'canonicalName', duplicates.canonical_name,
        'sourceNames', duplicates.source_names
      )
      order by duplicates.canonical_name
    ),
    '[]'::jsonb
  )
  into v_duplicate_resolution
  from (
    select
      p.canonical_name,
      jsonb_agg(rp.source_name order by rp.source_name) as source_names
    from resolved_players rp
    join bm.players p
      on p.id = rp.player_id
    group by p.id, p.canonical_name
    having count(*) > 1
  ) duplicates;

  if v_duplicate_resolution <> '[]'::jsonb then
    raise exception 'bm.publish_session duplicate canonical resolution within session %: %', v_id, v_duplicate_resolution::text;
  end if;

  if v_session_found then
    delete from bm.scheduled_games
    where session_internal_id = v_internal_id;

    delete from bm.fix_matches
    where session_internal_id = v_internal_id;

    delete from bm.session_players
    where session_internal_id = v_internal_id;

    delete from bm.session_courts
    where session_internal_id = v_internal_id;

    update bm.sessions
    set title = v_title,
        session_date = v_session_date,
        session_start = v_session_start,
        slot_minutes = v_slot_minutes,
        session_tier_count = v_session_tier_count,
        include_tier_count = v_include_tier_count,
        include_absent_players = v_include_absent_players,
        status = v_status,
        source = p_source,
        version = v_next_version,
        updated_at = now()
    where internal_id = v_internal_id;
  else
    insert into bm.sessions (
      id,
      internal_id,
      share_id,
      title,
      session_date,
      session_start,
      slot_minutes,
      session_tier_count,
      include_tier_count,
      include_absent_players,
      status,
      source,
      version
    )
    values (
      v_id,
      v_internal_id,
      v_share_id,
      v_title,
      v_session_date,
      v_session_start,
      v_slot_minutes,
      v_session_tier_count,
      v_include_tier_count,
      v_include_absent_players,
      v_status,
      p_source,
      v_next_version
    );
  end if;

  with court_indices as (
    select generate_series(
      0,
      greatest(
        coalesce(nullif(p_snapshot->'session'->>'courts', '')::integer, 0),
        coalesce(jsonb_array_length(coalesce(p_snapshot->'session'->'courtTimes', '[]'::jsonb)), 0)
      ) - 1
    ) as court_index
  )
  insert into bm.session_courts (
    session_internal_id,
    court_index,
    court_name,
    start_time,
    end_time
  )
  select
    v_internal_id,
    ci.court_index,
    coalesce(p_snapshot->'session'->'courtNames'->>ci.court_index, ''),
    coalesce(nullif(p_snapshot->'session'->'courtTimes'->ci.court_index->>'start', '')::time, v_session_start),
    coalesce(
      nullif(p_snapshot->'session'->'courtTimes'->ci.court_index->>'end', '')::time,
      v_session_start + make_interval(
        mins => v_slot_minutes * greatest(
          coalesce(nullif(p_snapshot->'session'->'slotsPerCourt'->>ci.court_index, '')::integer, 1),
          1
        )
      )
    )
  from court_indices ci;

  with snapshot_players as (
    select
      trim(player.value->>'id') as player_ref,
      coalesce(player.value->>'name', '') as source_name,
      bm.normalize_player_name(player.value->>'name') as normalized_name,
      coalesce(nullif(player.value->>'gender', ''), 'M') as gender,
      coalesce(nullif(player.value->>'tier', '')::integer, 1) as tier,
      player.ordinality - 1 as sort_order
    from jsonb_array_elements(coalesce(p_snapshot->'players', '[]'::jsonb)) with ordinality as player(value, ordinality)
  ),
  absent_players as (
    select nullif(trim(absent.value), '') as player_ref, absent.ordinality - 1 as absent_order
    from jsonb_array_elements_text(coalesce(p_snapshot->'absentPlayers', '[]'::jsonb)) with ordinality as absent(value, ordinality)
    where nullif(trim(absent.value), '') is not null
  ),
  resolved_players as (
    select
      sp.player_ref, sp.source_name, sp.gender, sp.tier, sp.sort_order, ap.absent_order, pa.player_id
    from snapshot_players sp
    join bm.player_aliases pa on pa.alias_name = sp.normalized_name
    left join absent_players ap on ap.player_ref = sp.player_ref
  )
  insert into bm.session_players (
    session_internal_id,
    player_id,
    player_ref,
    source_name,
    sort_order,
    absent_order,
    gender,
    tier,
    is_absent
  )
  select
    v_internal_id,
    rp.player_id,
    rp.player_ref,
    rp.source_name,
    rp.sort_order,
    rp.absent_order,
    rp.gender,
    rp.tier,
    rp.absent_order is not null
  from resolved_players rp
  order by rp.sort_order;

  with raw_fix_matches as (
    select coalesce(nullif(fm.value->>'id', ''), format('fix-%s', fm.ordinality - 1)) as legacy_ref, fm.ordinality - 1 as sort_order
    from jsonb_array_elements(coalesce(p_snapshot->'fixMatches', '[]'::jsonb)) with ordinality as fm(value, ordinality)
  )
  insert into bm.fix_matches (session_internal_id, legacy_ref, sort_order)
  select v_internal_id, rfm.legacy_ref, rfm.sort_order
  from raw_fix_matches rfm
  order by rfm.sort_order;

  with raw_fix_matches as (
    select
      coalesce(nullif(fm.value->>'id', ''), format('fix-%s', fm.ordinality - 1)) as legacy_ref,
      coalesce(fm.value->'slots', '[]'::jsonb) as slots_json
    from jsonb_array_elements(coalesce(p_snapshot->'fixMatches', '[]'::jsonb)) with ordinality as fm(value, ordinality)
  ),
  raw_slots as (
    select rfm.legacy_ref, slot.ordinality - 1 as slot_index, nullif(trim(slot.value), '') as player_ref
    from raw_fix_matches rfm
    cross join lateral jsonb_array_elements_text(rfm.slots_json) with ordinality as slot(value, ordinality)
  )
  insert into bm.fix_match_slots (
    fix_match_internal_id,
    slot_index,
    session_player_internal_id
  )
  select fm.internal_id, rs.slot_index, sp.internal_id
  from raw_slots rs
  join bm.fix_matches fm
    on fm.session_internal_id = v_internal_id
   and fm.legacy_ref = rs.legacy_ref
  left join bm.session_players sp
    on sp.session_internal_id = v_internal_id
   and sp.player_ref = rs.player_ref
  order by fm.sort_order, rs.slot_index;

  with raw_games as (
    select
      game.ordinality - 1 as legacy_order,
      (game.value->>'slot')::integer as slot_index,
      (game.value->>'court')::integer as court_index,
      exists (
        select 1
        from jsonb_array_elements_text(coalesce(p_snapshot->'playedGames', '[]'::jsonb)) as played(value)
        where played.value = concat(game.value->>'slot', '-', game.value->>'court')
      ) as is_played
    from jsonb_array_elements(coalesce(p_snapshot->'schedule', '[]'::jsonb)) with ordinality as game(value, ordinality)
  )
  insert into bm.scheduled_games (
    session_internal_id,
    legacy_order,
    slot_index,
    court_index,
    status,
    source
  )
  select
    v_internal_id,
    rg.legacy_order,
    rg.slot_index,
    rg.court_index,
    case when rg.is_played then 'played' else 'scheduled' end,
    case when p_source = 'legacy_snapshot' then 'legacy_snapshot' else 'compat_publish' end
  from raw_games rg
  order by rg.legacy_order;

  with raw_games as (
    select (game.value->>'slot')::integer as slot_index, (game.value->>'court')::integer as court_index, game.value as game_json
    from jsonb_array_elements(coalesce(p_snapshot->'schedule', '[]'::jsonb)) as game(value)
  ),
  raw_game_players as (
    select rg.slot_index, rg.court_index, 'A'::text as team, team_a.ordinality - 1 as position, trim(team_a.value) as player_ref
    from raw_games rg
    cross join lateral jsonb_array_elements_text(coalesce(rg.game_json->'teamA', '[]'::jsonb)) with ordinality as team_a(value, ordinality)
    union all
    select rg.slot_index, rg.court_index, 'B'::text as team, team_b.ordinality - 1 as position, trim(team_b.value) as player_ref
    from raw_games rg
    cross join lateral jsonb_array_elements_text(coalesce(rg.game_json->'teamB', '[]'::jsonb)) with ordinality as team_b(value, ordinality)
  )
  insert into bm.scheduled_game_players (
    scheduled_game_internal_id,
    session_player_internal_id,
    team,
    position
  )
  select sg.internal_id, sp.internal_id, rgp.team, rgp.position
  from raw_game_players rgp
  join bm.scheduled_games sg
    on sg.session_internal_id = v_internal_id
   and sg.slot_index = rgp.slot_index
   and sg.court_index = rgp.court_index
  join bm.session_players sp
    on sp.session_internal_id = v_internal_id
   and sp.player_ref = rgp.player_ref
  order by sg.legacy_order, rgp.team, rgp.position;

  insert into bm.game_progress (scheduled_game_internal_id, is_played, played_order)
  select
    sg.internal_id,
    played.played_order is not null,
    played.played_order
  from bm.scheduled_games sg
  left join (
    select played.value as game_key, played.ordinality - 1 as played_order
    from jsonb_array_elements_text(coalesce(p_snapshot->'playedGames', '[]'::jsonb)) with ordinality as played(value, ordinality)
  ) played
    on played.game_key = concat(sg.slot_index, '-', sg.court_index)
  where sg.session_internal_id = v_internal_id;

  insert into bm.game_scores (scheduled_game_internal_id, score_a, score_b)
  select sg.internal_id, (score.value->>'a')::integer, (score.value->>'b')::integer
  from jsonb_each(coalesce(p_snapshot->'gameScores', '{}'::jsonb)) as score(key, value)
  join bm.scheduled_games sg
    on sg.session_internal_id = v_internal_id
   and concat(sg.slot_index, '-', sg.court_index) = score.key;

  return bm.get_session(v_id);
end;
$$;

grant execute on function bm.publish_session(text, jsonb, text) to anon, authenticated, service_role;

-- ─────────────────────────────────────────────────────────────────────
-- bm.unlock_session
-- Source: 000050 (20260714_000050_bm_publish_unlock_rpc_fixes.sql)
-- ─────────────────────────────────────────────────────────────────────
create or replace function bm.unlock_session(p_id text)
returns jsonb
language plpgsql
security definer
set search_path = bm, public
as $$
declare
  v_lookup text := trim(coalesce(p_id, ''));
  v_internal_id uuid;
  v_current_status text;
begin
  if v_lookup = '' then
    raise exception 'session id must not be blank';
  end if;

  -- Advisory lock for mutual exclusion
  if not pg_try_advisory_xact_lock(hashtextextended(format('bm.unlock_session:%s', v_lookup), 0)) then
    raise exception 'session is being updated by another request; reload and retry';
  end if;

  select s.internal_id, s.status into v_internal_id, v_current_status
  from bm.sessions s
  where s.id = v_lookup
     or s.share_id = v_lookup
     or s.internal_id::text = v_lookup
  for update nowait;

  if v_internal_id is null then
    raise exception 'session not found: %', v_lookup;
  end if;

  -- Only unlock if actually locked
  if v_current_status = 'draft' then
    return bm.get_session(v_lookup);
  end if;

  -- M4: Bump version when resetting to draft
  update bm.sessions
  set status = 'draft',
      version = version + 1,
      updated_at = now()
  where internal_id = v_internal_id;

  return bm.get_session(v_lookup);
exception
  when lock_not_available then
    raise exception 'session is being updated by another request; reload and retry';
end;
$$;

-- Admin only — not exposed to anon or authenticated
grant execute on function bm.unlock_session(text) to service_role;
revoke execute on function bm.unlock_session(text) from anon, authenticated;

-- ─────────────────────────────────────────────────────────────────────
-- bm.publish_tournament
-- Source: 000042 (20260621_000042_bm_fix_publish_v_id_null_for_new_sessions.sql)
-- ─────────────────────────────────────────────────────────────────────
create or replace function bm.publish_tournament(p_id text, p_snapshot jsonb)
returns jsonb
language plpgsql
security definer
set search_path = bm, public
as $$
declare
  v_lookup text := trim(coalesce(p_id, ''));
  v_id text := v_lookup;
  v_share_id text := v_lookup;
  v_internal_id uuid := gen_random_uuid();
  v_tournament_found boolean;
  v_name text := coalesce(p_snapshot->>'name', p_id);
  v_event_date date := coalesce(nullif(p_snapshot->>'date', '')::date, current_date);
  v_expected_version integer := nullif(p_snapshot->>'version', '')::integer;
  v_current_version integer;
  v_next_version integer := 1;
begin
  if v_lookup = '' then
    raise exception 'tournament id must not be blank';
  end if;

  perform bm.validate_tournament_snapshot(p_snapshot);

  if not pg_try_advisory_xact_lock(hashtextextended(format('bm.publish_tournament:%s', v_lookup), 0)) then
    raise exception 'tournament is being updated by another request; reload and retry';
  end if;

  begin
    select t.id, t.share_id, t.internal_id, t.version
    into v_id, v_share_id, v_internal_id, v_current_version
    from bm.tournaments t
    where t.id = v_lookup
       or t.share_id = v_lookup
       or t.internal_id::text = v_lookup
    order by
      (t.id = v_lookup) desc,
      (t.share_id = v_lookup) desc
    for update nowait;
  exception
    when lock_not_available then
      raise exception 'tournament is being updated by another request; reload and retry';
  end;

  v_tournament_found := found;

  if not v_tournament_found then
    v_id := v_lookup;
    v_share_id := v_lookup;
    v_internal_id := gen_random_uuid();
  end if;

  if v_tournament_found then
    if v_expected_version is not null and v_expected_version <> v_current_version then
      raise exception 'tournament version mismatch: expected %, actual %', v_expected_version, v_current_version;
    end if;

    v_next_version := v_current_version + 1;
  elsif v_expected_version is not null then
    raise exception 'tournament version mismatch: expected %, actual null', v_expected_version;
  end if;

  insert into bm.tournaments (
    id,
    internal_id,
    share_id,
    name,
    event_date,
    snapshot,
    version,
    updated_at
  )
  values (
    v_id,
    v_internal_id,
    v_share_id,
    v_name,
    v_event_date,
    p_snapshot - 'version',
    v_next_version,
    now()
  )
  on conflict (id) do update
    set share_id = excluded.share_id,
        name = excluded.name,
        event_date = excluded.event_date,
        snapshot = excluded.snapshot,
        version = excluded.version,
        updated_at = now();

  return bm.get_tournament(v_id);
end;
$$;

grant execute on function bm.publish_tournament(text, jsonb) to anon, authenticated, service_role;

-- ─────────────────────────────────────────────────────────────────────
-- bm.delete_session
-- Source: 000051 (20260714_000051_bm_delete_session_lock_check_and_public_list_sessions_fix.sql)
-- ─────────────────────────────────────────────────────────────────────
create or replace function bm.delete_session(p_lookup text)
returns jsonb
language plpgsql
security definer
set search_path = bm, public
as $$
declare
  v_session_id text;
  v_share_id text;
  v_internal_id uuid;
  v_status text;
  v_session_count integer;
  v_court_count integer;
  v_player_count integer;
  v_fix_count integer;
  v_game_count integer;
begin
  if trim(coalesce(p_lookup, '')) = '' then
    raise exception 'session lookup must not be blank';
  end if;

  -- Resolve by id, share_id, or internal_id
  select s.id, s.share_id, s.internal_id
  into v_session_id, v_share_id, v_internal_id
  from bm.sessions s
  where s.id = p_lookup
     or s.share_id = p_lookup
     or s.internal_id::text = p_lookup
  order by
    (s.id = p_lookup) desc,
    (s.share_id = p_lookup) desc;

  if not found then
    raise exception 'session not found: %', p_lookup;
  end if;

  -- Check if session is locked (non-draft status)
  select s.status into v_status
  from bm.sessions s
  where s.internal_id = v_internal_id;

  if v_status <> 'draft' then
    raise exception 'cannot delete a locked session; unlock it first or use service_role';
  end if;

  -- Count what will be deleted (for the return summary)
  select count(*) into v_court_count from bm.session_courts where session_internal_id = v_internal_id;
  select count(*) into v_player_count from bm.session_players where session_internal_id = v_internal_id;
  select count(*) into v_fix_count from bm.fix_matches where session_internal_id = v_internal_id;
  select count(*) into v_game_count from bm.scheduled_games where session_internal_id = v_internal_id;

  -- Delete the session row — cascades handle all children:
  --   session_courts, session_players, fix_matches (→ fix_match_slots),
  --   scheduled_games (→ scheduled_game_players, game_progress, game_scores)
  delete from bm.sessions where internal_id = v_internal_id;

  return jsonb_build_object(
    'deleted', true,
    'sessionId', v_session_id,
    'shareId', v_share_id,
    'internalId', v_internal_id,
    'courts', v_court_count,
    'players', v_player_count,
    'fixMatches', v_fix_count,
    'games', v_game_count
  );
end;
$$;

grant execute on function bm.delete_session(text) to service_role;
revoke execute on function bm.delete_session(text) from anon, authenticated;

-- ─────────────────────────────────────────────────────────────────────
-- bm.delete_player
-- Source: 000040 (20260618_000040_fix_delete_player_use_id.sql)
-- ─────────────────────────────────────────────────────────────────────
create or replace function bm.delete_player(
  p_player_id uuid,
  p_force boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path = bm, public
as $$
declare
  v_canonical text;
  v_alias_count integer;
  v_session_ref_count integer;
  v_session_refs jsonb;
begin
  -- Verify player exists
  select canonical_name into v_canonical
  from bm.players where id = p_player_id;

  if not found then
    raise exception 'player not found: %', p_player_id;
  end if;

  -- Check session_players references (FK has no cascade)
  select count(*) into v_session_ref_count
  from bm.session_players where player_id = p_player_id;

  if v_session_ref_count > 0 and not p_force then
    select coalesce(jsonb_agg(jsonb_build_object(
      'sessionId', sp.session_id,
      'sourceName', sp.source_name
    ) order by sp.session_id), '[]'::jsonb)
    into v_session_refs
    from bm.session_players sp
    where sp.player_id = p_player_id;

    raise exception
      'player % is referenced in % session(s). Use p_force=true to remove. References: %',
      v_canonical, v_session_ref_count, v_session_refs::text;
  end if;

  -- Count aliases for summary (before cascade deletes them)
  select count(*) into v_alias_count from bm.player_aliases where player_id = p_player_id;

  -- Force: remove session_players rows first
  -- (cascade handles: fix_match_slots SET NULL, scheduled_game_players CASCADE)
  if v_session_ref_count > 0 then
    delete from bm.session_players where player_id = p_player_id;
  end if;

  -- Delete the player — ON DELETE CASCADE auto-removes player_aliases
  delete from bm.players where id = p_player_id;

  return jsonb_build_object(
    'deleted', true,
    'playerId', p_player_id,
    'canonicalName', v_canonical,
    'aliases', v_alias_count,
    'sessionRefsRemoved', v_session_ref_count
  );
end;
$$;

grant execute on function bm.delete_player(uuid, boolean) to service_role;
revoke execute on function bm.delete_player(uuid, boolean) from anon, authenticated;

-- ============================================================================
-- PUBLIC WRAPPER FUNCTIONS
-- ============================================================================

-- ─────────────────────────────────────────────────────────────────────
-- public.bm_get_session
-- Source: 000006 (20260617_000006_public_bm_rpc_wrappers.sql)
-- ─────────────────────────────────────────────────────────────────────
create or replace function public.bm_get_session(p_id text)
returns jsonb
language sql
security definer
set search_path = public, bm
as $$
  select bm.get_session(p_id);
$$;

grant execute on function public.bm_get_session(text) to anon, authenticated, service_role;

-- ─────────────────────────────────────────────────────────────────────
-- public.bm_publish_session
-- Source: 000007 (20260618_000007_bm_session_optimistic_concurrency.sql)
-- ─────────────────────────────────────────────────────────────────────
create or replace function public.bm_publish_session(p_id text, p_snapshot jsonb)
returns void
language plpgsql
security definer
set search_path = public, bm
as $$
begin
  perform bm.publish_session(p_id, p_snapshot);
end;
$$;

grant execute on function public.bm_publish_session(text, jsonb) to anon, authenticated, service_role;

-- ─────────────────────────────────────────────────────────────────────
-- public.bm_list_sessions
-- Source: 000051 (20260714_000051_bm_delete_session_lock_check_and_public_list_sessions_fix.sql)
-- ─────────────────────────────────────────────────────────────────────
create or replace function public.bm_list_sessions()
returns table (
  id text,
  title text,
  date text,
  player_count integer,
  total_games integer,
  locked boolean
)
language sql
security definer
set search_path = bm, public
as $$
  select * from bm.list_sessions();
$$;

grant execute on function public.bm_list_sessions() to anon, authenticated, service_role;

-- ─────────────────────────────────────────────────────────────────────
-- public.bm_list_players
-- Source: 000006 (20260617_000006_public_bm_rpc_wrappers.sql)
-- ─────────────────────────────────────────────────────────────────────
create or replace function public.bm_list_players()
returns table (
  name text,
  gender text,
  tier integer
)
language sql
security definer
set search_path = public, bm
as $$
  select *
  from bm.list_players();
$$;

grant execute on function public.bm_list_players() to anon, authenticated, service_role;

-- ─────────────────────────────────────────────────────────────────────
-- public.bm_get_player_stats
-- Source: 000006 (20260617_000006_public_bm_rpc_wrappers.sql)
-- ─────────────────────────────────────────────────────────────────────
create or replace function public.bm_get_player_stats(p_name text)
returns jsonb
language sql
security definer
set search_path = public, bm
as $$
  select bm.get_player_stats(p_name);
$$;

grant execute on function public.bm_get_player_stats(text) to anon, authenticated, service_role;

-- ─────────────────────────────────────────────────────────────────────
-- public.bm_publish_tournament
-- Source: 000010 (20260618_000010_bm_identity_and_tournament_concurrency.sql)
-- ─────────────────────────────────────────────────────────────────────
create or replace function public.bm_publish_tournament(p_id text, p_snapshot jsonb)
returns void
language plpgsql
security definer
set search_path = public, bm
as $$
begin
  perform bm.publish_tournament(p_id, p_snapshot);
end;
$$;

grant execute on function public.bm_publish_tournament(text, jsonb) to anon, authenticated, service_role;

-- ─────────────────────────────────────────────────────────────────────
-- public.bm_get_tournament
-- Source: 000006 (20260617_000006_public_bm_rpc_wrappers.sql)
-- ─────────────────────────────────────────────────────────────────────
create or replace function public.bm_get_tournament(p_id text)
returns jsonb
language sql
security definer
set search_path = public, bm
as $$
  select bm.get_tournament(p_id);
$$;

grant execute on function public.bm_get_tournament(text) to anon, authenticated, service_role;
