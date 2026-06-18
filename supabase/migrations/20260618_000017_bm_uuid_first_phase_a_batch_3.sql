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
      sp.is_absent
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
      (
        select jsonb_agg(coalesce(sp.player_ref, '') order by fms.slot_index)
        from bm.fix_match_slots fms
        left join bm.session_players sp
          on sp.id = fms.session_player_id
        where fms.fix_match_id = fm.id
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
    join resolved r
      on r.session_internal_id = sg.session_internal_id
    left join bm.game_progress gp
      on gp.scheduled_game_id = sg.id
    left join bm.game_scores gs
      on gs.scheduled_game_id = sg.id
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

create or replace function bm.list_sessions()
returns table (
  id text,
  title text,
  date text,
  player_count integer,
  total_games integer
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
    coalesce(game_counts.total_games, 0) as total_games
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
        order by s.session_date desc, sp.updated_at desc, sp.id desc
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
      sg.id as scheduled_game_id,
      sgp.team as player_team,
      gs.score_a,
      gs.score_b
    from target_memberships tm
    join bm.scheduled_game_players sgp
      on sgp.session_player_id = tm.session_player_id
    join bm.scheduled_games sg
      on sg.id = sgp.scheduled_game_id
     and sg.session_internal_id = tm.session_internal_id
    left join bm.game_scores gs
      on gs.scheduled_game_id = sg.id
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
      on teammate_link.scheduled_game_id = pg.scheduled_game_id
     and teammate_link.team = pg.player_team
     and teammate_link.session_player_id <> pg.session_player_id
    join bm.session_players teammate_sp
      on teammate_sp.id = teammate_link.session_player_id
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
      on opponent_link.scheduled_game_id = pg.scheduled_game_id
     and opponent_link.team <> pg.player_team
    join bm.session_players opponent_sp
      on opponent_sp.id = opponent_link.session_player_id
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

create or replace function bm.get_player_stats(p_name text)
returns jsonb
language sql
security definer
set search_path = bm, public
as $$
  select bm.get_player_stats_compat(p_name);
$$;

grant execute on function bm.get_player_stats(text) to anon, authenticated, service_role;
