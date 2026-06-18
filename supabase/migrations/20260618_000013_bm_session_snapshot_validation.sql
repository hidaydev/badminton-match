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

  if coalesce(p_snapshot->'session'->>'slotMinutes', '') <> '' and (p_snapshot->'session'->>'slotMinutes')::integer <= 0 then
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
  from jsonb_array_elements(p_snapshot->'players') player_item;

  if exists (
    select 1
    from jsonb_array_elements(p_snapshot->'players') player_item
    where jsonb_typeof(player_item) <> 'object'
       or trim(coalesce(player_item->>'id', '')) = ''
       or trim(coalesce(player_item->>'name', '')) = ''
       or coalesce(player_item->>'gender', 'M') not in ('M', 'F')
       or coalesce(nullif(player_item->>'tier', '')::integer, 1) not between 1 and 4
  ) then
    raise exception 'session players must contain non-blank id/name and valid gender/tier values';
  end if;

  if exists (
    select 1
    from (
      select trim(player_item->>'id') as player_ref, count(*) as c
      from jsonb_array_elements(p_snapshot->'players') player_item
      group by trim(player_item->>'id')
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
    from jsonb_array_elements(coalesce(p_snapshot->'session'->'courtTimes', '[]'::jsonb)) court_time
    where jsonb_typeof(court_time) <> 'object'
       or coalesce(court_time->>'start', '') = ''
       or coalesce(court_time->>'end', '') = ''
       or (court_time->>'end')::time <= (court_time->>'start')::time
  ) then
    raise exception 'session courtTimes entries must contain valid ascending start/end times';
  end if;

  if exists (
    select 1
    from jsonb_array_elements_text(coalesce(p_snapshot->'session'->'slotsPerCourt', '[]'::jsonb)) slot_count(value)
    where nullif(slot_count.value, '')::integer < 0
  ) then
    raise exception 'session slotsPerCourt values must be non-negative';
  end if;

  select count(*)
  into v_schedule_count
  from jsonb_array_elements(p_snapshot->'schedule') schedule_item;

  if p_snapshot->'session' ? 'totalGames'
     and coalesce(nullif(p_snapshot->'session'->>'totalGames', '')::integer, -1) <> v_schedule_count then
    raise exception 'session snapshot.session.totalGames must match schedule length';
  end if;

  if exists (
    select 1
    from jsonb_array_elements(p_snapshot->'schedule') schedule_item
    where jsonb_typeof(schedule_item) <> 'object'
       or nullif(schedule_item->>'slot', '') is null
       or nullif(schedule_item->>'court', '') is null
       or (schedule_item->>'slot')::integer < 0
       or (schedule_item->>'court')::integer < 0
       or jsonb_typeof(coalesce(schedule_item->'teamA', 'null'::jsonb)) <> 'array'
       or jsonb_typeof(coalesce(schedule_item->'teamB', 'null'::jsonb)) <> 'array'
       or jsonb_array_length(schedule_item->'teamA') <> 2
       or jsonb_array_length(schedule_item->'teamB') <> 2
  ) then
    raise exception 'session schedule entries must have non-negative slot/court and 2 players per team';
  end if;

  if exists (
    select 1
    from (
      select
        (schedule_item->>'slot')::integer as slot_index,
        (schedule_item->>'court')::integer as court_index,
        count(*) as c
      from jsonb_array_elements(p_snapshot->'schedule') schedule_item
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
      from jsonb_array_elements(p_snapshot->'schedule') schedule_item
      cross join lateral jsonb_array_elements_text(schedule_item->'teamA') team_a(value)

      union all

      select trim(team_b.value)
      from jsonb_array_elements(p_snapshot->'schedule') schedule_item
      cross join lateral jsonb_array_elements_text(schedule_item->'teamB') team_b(value)
    ) scheduled_ref
    left join (
      select trim(player_item->>'id') as player_ref
      from jsonb_array_elements(p_snapshot->'players') player_item
    ) players
      on players.player_ref = scheduled_ref.player_ref
    where scheduled_ref.player_ref = ''
       or players.player_ref is null
  ) then
    raise exception 'session schedule must only reference known non-blank player ids';
  end if;

  if exists (
    select 1
    from jsonb_array_elements(p_snapshot->'schedule') schedule_item
    where (
      select count(*)
      from (
        select trim(team_a.value) as player_ref
        from jsonb_array_elements_text(schedule_item->'teamA') team_a(value)
        union all
        select trim(team_b.value)
        from jsonb_array_elements_text(schedule_item->'teamB') team_b(value)
      ) all_players
    ) <> (
      select count(distinct player_ref)
      from (
        select trim(team_a.value) as player_ref
        from jsonb_array_elements_text(schedule_item->'teamA') team_a(value)
        union all
        select trim(team_b.value)
        from jsonb_array_elements_text(schedule_item->'teamB') team_b(value)
      ) all_players
    )
  ) then
    raise exception 'session schedule entries must not repeat a player within the same game';
  end if;

  if exists (
    select 1
    from jsonb_array_elements(p_snapshot->'fixMatches') fix_match_item
    where jsonb_typeof(fix_match_item) <> 'object'
       or jsonb_typeof(coalesce(fix_match_item->'slots', 'null'::jsonb)) <> 'array'
       or jsonb_array_length(fix_match_item->'slots') > 4
  ) then
    raise exception 'session fixMatches entries must contain a slots array with at most 4 items';
  end if;

  if exists (
    select 1
    from (
      select coalesce(nullif(fix_match_item->>'id', ''), format('fix-%s', ordinality - 1)) as legacy_ref, count(*) as c
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
      from jsonb_array_elements(p_snapshot->'fixMatches') fix_match_item
      cross join lateral jsonb_array_elements_text(coalesce(fix_match_item->'slots', '[]'::jsonb)) slot(value)
    ) fix_ref
    left join (
      select trim(player_item->>'id') as player_ref
      from jsonb_array_elements(p_snapshot->'players') player_item
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
      from jsonb_array_elements_text(coalesce(p_snapshot->'absentPlayers', '[]'::jsonb)) absent_player(value)
    ) absent_ref
    left join (
      select trim(player_item->>'id') as player_ref
      from jsonb_array_elements(p_snapshot->'players') player_item
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
        from jsonb_array_elements_text(coalesce(p_snapshot->'absentPlayers', '[]'::jsonb)) absent_player(value)
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
      from jsonb_array_elements_text(p_snapshot->'playedGames') played_game(value)
    ) played_ref
    left join (
      select concat((schedule_item->>'slot')::integer, '-', (schedule_item->>'court')::integer) as game_key
      from jsonb_array_elements(p_snapshot->'schedule') schedule_item
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
      from jsonb_array_elements_text(p_snapshot->'playedGames') played_game(value)
      group by played_game.value
      having count(*) > 1
    ) dup_played
  ) then
    raise exception 'session playedGames must not contain duplicates';
  end if;

  if exists (
    select 1
    from jsonb_array_elements(p_snapshot->'schedule') schedule_item
    where exists (
      select 1
      from jsonb_each(p_snapshot->'gameScores') score_entry
      where score_entry.key = concat((schedule_item->>'slot')::integer, '-', (schedule_item->>'court')::integer)
    )
      and not exists (
        select 1
        from jsonb_array_elements_text(p_snapshot->'playedGames') played_game(value)
        where played_game.value = concat((schedule_item->>'slot')::integer, '-', (schedule_item->>'court')::integer)
      )
  ) then
    raise exception 'session gameScores must only exist for games listed in playedGames';
  end if;

  if exists (
    select 1
    from jsonb_each(p_snapshot->'gameScores') score_entry
    left join (
      select concat((schedule_item->>'slot')::integer, '-', (schedule_item->>'court')::integer) as game_key
      from jsonb_array_elements(p_snapshot->'schedule') schedule_item
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

create or replace function bm.publish_session(
  p_id text,
  p_snapshot jsonb,
  p_source text default 'compat_publish'
)
returns jsonb
language plpgsql
security definer
set search_path = bm, badminton_match, public
as $$
declare
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
  if trim(coalesce(p_id, '')) = '' then
    raise exception 'session id must not be blank';
  end if;

  perform bm.validate_session_snapshot(p_snapshot);

  if p_source not in ('compat_publish', 'legacy_snapshot', 'manual') then
    raise exception 'unsupported bm session source: %', p_source;
  end if;

  if v_slot_minutes <= 0 then
    raise exception 'slotMinutes must be positive for session %', p_id;
  end if;

  begin
    select s.version
    into v_current_version
    from bm.sessions s
    where s.id = p_id
    for update nowait;
  exception
    when lock_not_available then
      raise exception 'session is being updated by another request; reload and retry';
  end;

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
    select distinct sp.source_name, sp.normalized_name
    from snapshot_players sp
    left join bm.player_aliases pa
      on pa.alias_name = sp.normalized_name
    where sp.normalized_name is null
       or pa.player_id is null
  ) unresolved;

  if v_unresolved <> '[]'::jsonb then
    raise exception 'bm.publish_session unresolved player names for %: %', p_id, v_unresolved::text;
  end if;

  with snapshot_players as (
    select
      trim(player.value->>'id') as player_ref
    from jsonb_array_elements(coalesce(p_snapshot->'players', '[]'::jsonb)) as player(value)
  ),
  referenced_ids as (
    select distinct nullif(trim(slot.value), '') as player_ref
    from jsonb_array_elements(coalesce(p_snapshot->'fixMatches', '[]'::jsonb)) as fm(value)
    cross join lateral jsonb_array_elements_text(coalesce(fm.value->'slots', '[]'::jsonb)) as slot(value)

    union

    select distinct nullif(trim(team_a.value), '') as player_ref
    from jsonb_array_elements(coalesce(p_snapshot->'schedule', '[]'::jsonb)) as game(value)
    cross join lateral jsonb_array_elements_text(coalesce(game.value->'teamA', '[]'::jsonb)) as team_a(value)

    union

    select distinct nullif(trim(team_b.value), '') as player_ref
    from jsonb_array_elements(coalesce(p_snapshot->'schedule', '[]'::jsonb)) as game(value)
    cross join lateral jsonb_array_elements_text(coalesce(game.value->'teamB', '[]'::jsonb)) as team_b(value)

    union

    select distinct nullif(trim(absent.value), '') as player_ref
    from jsonb_array_elements_text(coalesce(p_snapshot->'absentPlayers', '[]'::jsonb)) as absent(value)
  )
  select coalesce(
    jsonb_agg(to_jsonb(invalid.player_ref) order by invalid.player_ref),
    '[]'::jsonb
  )
  into v_invalid_refs
  from (
    select distinct rid.player_ref
    from referenced_ids rid
    left join snapshot_players sp
      on sp.player_ref = rid.player_ref
    where rid.player_ref is not null
      and sp.player_ref is null
  ) invalid;

  if v_invalid_refs <> '[]'::jsonb then
    raise exception 'bm.publish_session invalid player refs for %: %', p_id, v_invalid_refs::text;
  end if;

  with snapshot_players as (
    select
      trim(player.value->>'id') as player_ref,
      coalesce(player.value->>'name', '') as source_name,
      bm.normalize_player_name(player.value->>'name') as normalized_name
    from jsonb_array_elements(coalesce(p_snapshot->'players', '[]'::jsonb)) as player(value)
  ),
  resolved_players as (
    select
      sp.player_ref,
      sp.source_name,
      pa.player_id
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
    raise exception 'bm.publish_session duplicate canonical resolution within session %: %', p_id, v_duplicate_resolution::text;
  end if;

  delete from bm.sessions where id = p_id;

  insert into bm.sessions (
    id,
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
    p_id,
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
    session_id,
    court_index,
    court_name,
    start_time,
    end_time
  )
  select
    p_id,
    ci.court_index,
    coalesce(p_snapshot->'session'->'courtNames'->>ci.court_index, ''),
    coalesce(
      nullif(p_snapshot->'session'->'courtTimes'->ci.court_index->>'start', '')::time,
      v_session_start
    ),
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
    select
      nullif(trim(absent.value), '') as player_ref,
      absent.ordinality - 1 as absent_order
    from jsonb_array_elements_text(coalesce(p_snapshot->'absentPlayers', '[]'::jsonb)) with ordinality as absent(value, ordinality)
    where nullif(trim(absent.value), '') is not null
  ),
  resolved_players as (
    select
      sp.player_ref,
      sp.source_name,
      sp.gender,
      sp.tier,
      sp.sort_order,
      ap.absent_order,
      pa.player_id
    from snapshot_players sp
    join bm.player_aliases pa
      on pa.alias_name = sp.normalized_name
    left join absent_players ap
      on ap.player_ref = sp.player_ref
  )
  insert into bm.session_players (
    session_id,
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
    p_id,
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
    select
      coalesce(nullif(fm.value->>'id', ''), format('fix-%s', fm.ordinality - 1)) as legacy_ref,
      fm.ordinality - 1 as sort_order
    from jsonb_array_elements(coalesce(p_snapshot->'fixMatches', '[]'::jsonb)) with ordinality as fm(value, ordinality)
  )
  insert into bm.fix_matches (
    session_id,
    legacy_ref,
    sort_order
  )
  select
    p_id,
    rfm.legacy_ref,
    rfm.sort_order
  from raw_fix_matches rfm
  order by rfm.sort_order;

  with raw_fix_matches as (
    select
      coalesce(nullif(fm.value->>'id', ''), format('fix-%s', fm.ordinality - 1)) as legacy_ref,
      coalesce(fm.value->'slots', '[]'::jsonb) as slots_json
    from jsonb_array_elements(coalesce(p_snapshot->'fixMatches', '[]'::jsonb)) with ordinality as fm(value, ordinality)
  ),
  raw_slots as (
    select
      rfm.legacy_ref,
      slot.ordinality - 1 as slot_index,
      nullif(trim(slot.value), '') as player_ref
    from raw_fix_matches rfm
    cross join lateral jsonb_array_elements_text(rfm.slots_json) with ordinality as slot(value, ordinality)
  )
  insert into bm.fix_match_slots (
    fix_match_id,
    slot_index,
    session_player_id
  )
  select
    fm.id,
    rs.slot_index,
    sp.id
  from raw_slots rs
  join bm.fix_matches fm
    on fm.session_id = p_id
   and fm.legacy_ref = rs.legacy_ref
  left join bm.session_players sp
    on sp.session_id = p_id
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
    session_id,
    legacy_order,
    slot_index,
    court_index,
    status,
    source
  )
  select
    p_id,
    rg.legacy_order,
    rg.slot_index,
    rg.court_index,
    case when rg.is_played then 'played' else 'scheduled' end,
    case when p_source = 'legacy_snapshot' then 'legacy_snapshot' else 'compat_publish' end
  from raw_games rg
  order by rg.legacy_order;

  with raw_games as (
    select
      (game.value->>'slot')::integer as slot_index,
      (game.value->>'court')::integer as court_index,
      game.value as game_json
    from jsonb_array_elements(coalesce(p_snapshot->'schedule', '[]'::jsonb)) as game(value)
  ),
  raw_game_players as (
    select
      rg.slot_index,
      rg.court_index,
      'A'::text as team,
      team_a.ordinality - 1 as position,
      trim(team_a.value) as player_ref
    from raw_games rg
    cross join lateral jsonb_array_elements_text(coalesce(rg.game_json->'teamA', '[]'::jsonb)) with ordinality as team_a(value, ordinality)

    union all

    select
      rg.slot_index,
      rg.court_index,
      'B'::text as team,
      team_b.ordinality - 1 as position,
      trim(team_b.value) as player_ref
    from raw_games rg
    cross join lateral jsonb_array_elements_text(coalesce(rg.game_json->'teamB', '[]'::jsonb)) with ordinality as team_b(value, ordinality)
  )
  insert into bm.scheduled_game_players (
    scheduled_game_id,
    session_player_id,
    team,
    position
  )
  select
    sg.id,
    sp.id,
    rgp.team,
    rgp.position
  from raw_game_players rgp
  join bm.scheduled_games sg
    on sg.session_id = p_id
   and sg.slot_index = rgp.slot_index
   and sg.court_index = rgp.court_index
  join bm.session_players sp
    on sp.session_id = p_id
   and sp.player_ref = rgp.player_ref
  order by sg.legacy_order, rgp.team, rgp.position;

  insert into bm.game_progress (
    scheduled_game_id,
    is_played,
    played_order
  )
  select
    sg.id,
    played.played_order is not null,
    played.played_order
  from bm.scheduled_games sg
  left join (
    select
      played.value as game_key,
      played.ordinality - 1 as played_order
    from jsonb_array_elements_text(coalesce(p_snapshot->'playedGames', '[]'::jsonb)) with ordinality as played(value, ordinality)
  ) played
    on played.game_key = concat(sg.slot_index, '-', sg.court_index)
  where sg.session_id = p_id;

  insert into bm.game_scores (
    scheduled_game_id,
    score_a,
    score_b
  )
  select
    sg.id,
    (score.value->>'a')::integer,
    (score.value->>'b')::integer
  from jsonb_each(coalesce(p_snapshot->'gameScores', '{}'::jsonb)) as score(key, value)
  join bm.scheduled_games sg
    on sg.session_id = p_id
   and concat(sg.slot_index, '-', sg.court_index) = score.key;

  return bm.get_session(p_id);
end;
$$;

grant execute on function bm.publish_session(text, jsonb, text) to anon, authenticated, service_role;
