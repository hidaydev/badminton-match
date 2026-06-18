alter table bm.sessions
  add column if not exists session_tier_count integer not null default 0;

alter table bm.sessions
  add column if not exists include_tier_count boolean not null default false;

alter table bm.sessions
  add column if not exists include_absent_players boolean not null default false;

alter table bm.session_players
  add column if not exists absent_order integer check (absent_order is null or absent_order >= 0);

alter table bm.scheduled_games
  add column if not exists legacy_order integer;

alter table bm.game_progress
  add column if not exists played_order integer;

create unique index if not exists bm_scheduled_games_session_legacy_order_idx
  on bm.scheduled_games (session_id, legacy_order);

create or replace function bm.publish_session(
  p_id text,
  p_snapshot jsonb,
  p_source text default 'compat_publish'
)
returns void
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
begin
  if trim(coalesce(p_id, '')) = '' then
    raise exception 'session id must not be blank';
  end if;

  if p_snapshot is null then
    raise exception 'session snapshot must not be null';
  end if;

  if p_source not in ('compat_publish', 'legacy_snapshot', 'manual') then
    raise exception 'unsupported bm session source: %', p_source;
  end if;

  if v_slot_minutes <= 0 then
    raise exception 'slotMinutes must be positive for session %', p_id;
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
    source
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
    p_source
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
end;
$$;

create or replace function bm.get_session_snapshot_compat(p_id text)
returns jsonb
language sql
security definer
set search_path = bm, public
as $$
  with target_session as (
    select *
    from bm.sessions
    where id = p_id
  ),
  court_rows as (
    select
      sc.session_id,
      sc.court_index,
      sc.court_name,
      sc.start_time,
      sc.end_time,
      coalesce(game_counts.game_count, 0) as game_count
    from bm.session_courts sc
    left join (
      select
        sg.session_id,
        sg.court_index,
        count(*)::integer as game_count
      from bm.scheduled_games sg
      group by sg.session_id, sg.court_index
    ) game_counts
      on game_counts.session_id = sc.session_id
     and game_counts.court_index = sc.court_index
    where sc.session_id = p_id
  ),
  player_rows as (
    select
      sp.session_id,
      sp.sort_order,
      sp.absent_order,
      sp.player_ref,
      sp.source_name,
      sp.gender,
      sp.tier,
      sp.is_absent
    from bm.session_players sp
    where sp.session_id = p_id
  ),
  fix_match_rows as (
    select
      fm.session_id,
      fm.sort_order,
      fm.legacy_ref,
      (
        select jsonb_agg(coalesce(sp.player_ref, '') order by fms.slot_index)
        from bm.fix_match_slots fms
        left join bm.session_players sp
          on sp.id = fms.session_player_id
        where fms.fix_match_id = fm.id
      ) as slots_json
    from bm.fix_matches fm
    where fm.session_id = p_id
  ),
  game_rows as (
    select
      sg.session_id,
      sg.legacy_order,
      sg.slot_index,
      sg.court_index,
      gp.is_played,
      gp.played_order,
      gs.score_a,
      gs.score_b,
      (
        select jsonb_agg(sp.player_ref order by sgp.position)
        from bm.scheduled_game_players sgp
        join bm.session_players sp
          on sp.id = sgp.session_player_id
        where sgp.scheduled_game_id = sg.id
          and sgp.team = 'A'
      ) as team_a_json,
      (
        select jsonb_agg(sp.player_ref order by sgp.position)
        from bm.scheduled_game_players sgp
        join bm.session_players sp
          on sp.id = sgp.session_player_id
        where sgp.scheduled_game_id = sg.id
          and sgp.team = 'B'
      ) as team_b_json
    from bm.scheduled_games sg
    left join bm.game_progress gp
      on gp.scheduled_game_id = sg.id
    left join bm.game_scores gs
      on gs.scheduled_game_id = sg.id
    where sg.session_id = p_id
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
