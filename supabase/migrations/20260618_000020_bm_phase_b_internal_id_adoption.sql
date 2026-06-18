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
    session_id,
    session_internal_id,
    court_index,
    court_name,
    start_time,
    end_time
  )
  select
    v_id,
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
    session_id,
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
    v_id,
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
  insert into bm.fix_matches (session_id, session_internal_id, legacy_ref, sort_order)
  select v_id, v_internal_id, rfm.legacy_ref, rfm.sort_order
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
    fix_match_id,
    fix_match_internal_id,
    slot_index,
    session_player_id,
    session_player_internal_id
  )
  select fm.id, fm.internal_id, rs.slot_index, sp.id, sp.internal_id
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
    session_id,
    session_internal_id,
    legacy_order,
    slot_index,
    court_index,
    status,
    source
  )
  select
    v_id,
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
    scheduled_game_id,
    scheduled_game_internal_id,
    session_player_id,
    session_player_internal_id,
    team,
    position
  )
  select sg.id, sg.internal_id, sp.id, sp.internal_id, rgp.team, rgp.position
  from raw_game_players rgp
  join bm.scheduled_games sg
    on sg.session_internal_id = v_internal_id
   and sg.slot_index = rgp.slot_index
   and sg.court_index = rgp.court_index
  join bm.session_players sp
    on sp.session_internal_id = v_internal_id
   and sp.player_ref = rgp.player_ref
  order by sg.legacy_order, rgp.team, rgp.position;

  insert into bm.game_progress (scheduled_game_id, scheduled_game_internal_id, is_played, played_order)
  select
    sg.id,
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

  insert into bm.game_scores (scheduled_game_id, scheduled_game_internal_id, score_a, score_b)
  select sg.id, sg.internal_id, (score.value->>'a')::integer, (score.value->>'b')::integer
  from jsonb_each(coalesce(p_snapshot->'gameScores', '{}'::jsonb)) as score(key, value)
  join bm.scheduled_games sg
    on sg.session_internal_id = v_internal_id
   and concat(sg.slot_index, '-', sg.court_index) = score.key;

  return bm.get_session(v_id);
end;
$$;

grant execute on function bm.publish_session(text, jsonb, text) to anon, authenticated, service_role;

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
      sp.id as session_player_id,
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
      tm.session_player_id,
      tm.session_player_internal_id,
      sg.id as scheduled_game_id,
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
