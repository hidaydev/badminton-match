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

alter table bm.session_courts
  drop constraint if exists session_courts_pkey;

alter table bm.session_courts
  add constraint session_courts_pkey primary key (internal_id);

alter table bm.session_courts
  drop column if exists id;

alter table bm.session_players
  drop constraint if exists session_players_pkey;

alter table bm.session_players
  add constraint session_players_pkey primary key (internal_id);

alter table bm.session_players
  drop column if exists id;

alter table bm.fix_matches
  drop constraint if exists fix_matches_pkey;

alter table bm.fix_matches
  add constraint fix_matches_pkey primary key (internal_id);

alter table bm.fix_matches
  drop column if exists id;

alter table bm.scheduled_games
  drop constraint if exists scheduled_games_pkey;

alter table bm.scheduled_games
  add constraint scheduled_games_pkey primary key (internal_id);

alter table bm.scheduled_games
  drop column if exists id;
