-- Fix publish_session/publish_tournament: v_internal_id overwritten to NULL for new rows
--
-- Pre-existing bug since migration 000022. The variable v_internal_id is
-- initialized to gen_random_uuid() in the DECLARE block, then SELECT...INTO
-- overwrites it to NULL when the session/tournament doesn't exist yet.
-- Subsequent INSERTs into child tables (session_courts etc.) set
-- session_internal_id = NULL, triggering "session identity is required".
--
-- The INSERT path (brand new session) was never exercised before because:
-- - all existing sessions were backfilled from legacy data
-- - smoke tests only republish existing sessions
-- - the app only started creating new sessions after the Supabase migration
--
-- Fix: after the SELECT block, regenerate v_internal_id when not found.

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
  v_title text := coalesce(p_snapshot->'session'->>'title', '');
  v_session_date date := coalesce(nullif(p_snapshot->'session'->>'date', '')::date, current_date);
  v_session_start time := coalesce(nullif(p_snapshot->'session'->>'sessionStart', '')::time, '00:00'::time);
  v_slot_minutes integer := coalesce(nullif(p_snapshot->'session'->>'slotMinutes', '')::integer, 20);
  v_session_tier_count integer := coalesce(nullif(p_snapshot->'session'->>'tierCount', '')::integer, 0);
  v_include_tier_count boolean := coalesce((p_snapshot->'session') ? 'tierCount', false);
  v_include_absent_players boolean := p_snapshot ? 'absentPlayers';
  v_status text := case
    when coalesce((p_snapshot->'session'->>'locked')::boolean, false) then 'published'
    else 'draft'
  end;
  v_unresolved jsonb := '[]'::jsonb;
  v_duplicate_resolution jsonb := '[]'::jsonb;
  v_invalid_refs jsonb := '[]'::jsonb;
  v_expected_version integer := nullif(p_snapshot->>'version', '')::integer;
  v_current_version integer;
  v_next_version integer := 1;
begin
  if v_lookup = '' then
    raise exception 'session id must not be blank';
  end if;

  perform bm.validate_session_snapshot(p_snapshot);

  if p_source not in ('compat_publish', 'legacy_snapshot', 'manual') then
    raise exception 'unsupported bm session source: %', p_source;
  end if;

  if v_slot_minutes <= 0 then
    raise exception 'slotMinutes must be positive for session %', v_lookup;
  end if;

  begin
    select s.id, s.share_id, s.internal_id, s.version
    into v_id, v_share_id, v_internal_id, v_current_version
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

  -- SELECT...INTO above sets v_internal_id to NULL when no session is found
  -- (new session). Regenerate so INSERT into child tables has a valid uuid.
  if not found then
    v_internal_id := gen_random_uuid();
  end if;

  if found then
    if v_expected_version is not null and v_expected_version <> v_current_version then
      raise exception 'session version mismatch: expected %, actual %', v_expected_version, v_current_version;
    end if;

    v_next_version := v_current_version + 1;
  elsif v_expected_version is not null then
    raise exception 'session version mismatch: expected %, actual null', v_expected_version;
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
    where pa.player_id is null
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

  if found then
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

-- Same fix for publish_tournament
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

  -- SELECT...INTO above sets v_internal_id to NULL when not found. Regenerate.
  if not found then
    v_internal_id := gen_random_uuid();
  end if;

  if found then
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
