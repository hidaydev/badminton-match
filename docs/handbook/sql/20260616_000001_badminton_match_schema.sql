create schema if not exists badminton_match;

create table if not exists badminton_match.sessions (
  id text primary key,
  title text not null default '',
  session_date date not null,
  player_count integer not null,
  total_games integer not null,
  published_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  snapshot jsonb not null
);

create index if not exists sessions_session_date_idx
  on badminton_match.sessions (session_date desc);

create index if not exists sessions_updated_at_idx
  on badminton_match.sessions (updated_at desc);

create table if not exists badminton_match.tournaments (
  id text primary key,
  name text not null,
  event_date date not null,
  updated_at timestamptz not null default now(),
  snapshot jsonb not null
);

create index if not exists tournaments_event_date_idx
  on badminton_match.tournaments (event_date desc);

create table if not exists badminton_match.session_exports (
  id uuid primary key default gen_random_uuid(),
  session_id text not null references badminton_match.sessions(id) on delete cascade,
  export_version integer not null,
  export_kind text not null default 'session_result',
  created_at timestamptz not null default now(),
  payload jsonb not null
);

create index if not exists session_exports_session_id_idx
  on badminton_match.session_exports (session_id);

create index if not exists session_exports_created_at_idx
  on badminton_match.session_exports (created_at desc);

create or replace function public.bm_publish_session(p_id text, p_snapshot jsonb)
returns void
language plpgsql
security definer
set search_path = public, badminton_match
as $$
declare
  v_title text;
  v_session_date date;
  v_player_count integer;
  v_total_games integer;
begin
  v_title := coalesce(p_snapshot->'session'->>'title', '');
  v_session_date := coalesce((p_snapshot->'session'->>'date')::date, current_date);
  v_player_count := coalesce(jsonb_array_length(coalesce(p_snapshot->'players', '[]'::jsonb)), 0);
  v_total_games := coalesce(jsonb_array_length(coalesce(p_snapshot->'schedule', '[]'::jsonb)), 0);

  insert into badminton_match.sessions (
    id,
    title,
    session_date,
    player_count,
    total_games,
    snapshot,
    published_at,
    updated_at
  )
  values (
    p_id,
    v_title,
    v_session_date,
    v_player_count,
    v_total_games,
    p_snapshot,
    now(),
    now()
  )
  on conflict (id) do update
    set title = excluded.title,
        session_date = excluded.session_date,
        player_count = excluded.player_count,
        total_games = excluded.total_games,
        snapshot = excluded.snapshot,
        updated_at = now();
end;
$$;

create or replace function public.bm_get_session(p_id text)
returns jsonb
language sql
security definer
set search_path = public, badminton_match
as $$
  select s.snapshot
  from badminton_match.sessions s
  where s.id = p_id;
$$;

create or replace function public.bm_list_sessions()
returns table (
  id text,
  title text,
  date text,
  player_count integer,
  total_games integer
)
language sql
security definer
set search_path = public, badminton_match
as $$
  select
    s.id,
    s.title,
    s.session_date::text as date,
    s.player_count,
    s.total_games
  from badminton_match.sessions s
  order by s.session_date desc, s.updated_at desc;
$$;

create or replace function public.bm_list_players()
returns table (
  name text,
  gender text,
  tier integer
)
language sql
security definer
set search_path = public, badminton_match
as $$
  with expanded as (
    select
      lower(player->>'name') as name_key,
      player->>'name' as name,
      player->>'gender' as gender,
      (player->>'tier')::integer as tier,
      s.session_date
    from badminton_match.sessions s
    cross join lateral jsonb_array_elements(coalesce(s.snapshot->'players', '[]'::jsonb)) as player
    where player->>'name' is not null
  ),
  ranked as (
    select
      e.*,
      row_number() over (
        partition by e.name_key
        order by e.session_date desc, e.name asc
      ) as rn
    from expanded e
  )
  select
    r.name,
    r.gender,
    r.tier
  from ranked r
  where r.rn = 1
  order by lower(r.name);
$$;

create or replace function public.bm_get_player_stats(p_name text)
returns jsonb
language plpgsql
security definer
set search_path = public, badminton_match
as $$
declare
  v_name_lower text := lower(trim(p_name));
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
  with session_players as (
    select
      s.id as session_id,
      s.title,
      s.session_date,
      player->>'id' as player_id,
      player->>'name' as player_name
    from badminton_match.sessions s
    cross join lateral jsonb_array_elements(coalesce(s.snapshot->'players', '[]'::jsonb)) as player
  ),
  target_players as (
    select *
    from session_players
    where lower(player_name) = v_name_lower
  ),
  session_rows as (
    select distinct
      tp.session_id as id,
      tp.session_date::text as date,
      coalesce(tp.title, '') as title,
      exists (
        select 1
        from badminton_match.sessions s
        cross join lateral jsonb_array_elements_text(coalesce(s.snapshot->'absentPlayers', '[]'::jsonb)) as absent(player_id)
        where s.id = tp.session_id
          and absent.player_id = tp.player_id
      ) as absent
    from target_players tp
  ),
  games as (
    select
      tp.player_name,
      tp.player_id,
      s.id as session_id,
      s.title,
      s.session_date,
      game.value as game,
      score.value as score
    from target_players tp
    join badminton_match.sessions s on s.id = tp.session_id
    cross join lateral jsonb_array_elements(coalesce(s.snapshot->'schedule', '[]'::jsonb)) as game(value)
    left join lateral (
      select kv.value
      from jsonb_each(coalesce(s.snapshot->'gameScores', '{}'::jsonb)) as kv(key, value)
      where kv.key = concat(game.value->>'slot', '-', game.value->>'court')
    ) as score on true
    where exists (
      select 1
      from jsonb_array_elements_text(coalesce(game.value->'teamA', '[]'::jsonb)) as a(pid)
      where a.pid = tp.player_id
    )
    or exists (
      select 1
      from jsonb_array_elements_text(coalesce(game.value->'teamB', '[]'::jsonb)) as b(pid)
      where b.pid = tp.player_id
    )
  ),
  player_lookup as (
    select
      s.id as session_id,
      player->>'id' as player_id,
      player->>'name' as player_name
    from badminton_match.sessions s
    cross join lateral jsonb_array_elements(coalesce(s.snapshot->'players', '[]'::jsonb)) as player
  ),
  enriched_games as (
    select
      g.*,
      exists (
        select 1 from jsonb_array_elements_text(coalesce(g.game->'teamA', '[]'::jsonb)) as a(pid)
        where a.pid = g.player_id
      ) as in_a
    from games g
  ),
  base_stats as (
    select
      count(*)::integer as games_played,
      coalesce(sum(case
        when eg.score is null then 0
        when eg.in_a and (eg.score->>'a')::integer > (eg.score->>'b')::integer then 1
        when not eg.in_a and (eg.score->>'b')::integer > (eg.score->>'a')::integer then 1
        else 0
      end), 0)::integer as wins,
      coalesce(sum(case
        when eg.score is null then 0
        when eg.in_a and (eg.score->>'a')::integer < (eg.score->>'b')::integer then 1
        when not eg.in_a and (eg.score->>'b')::integer < (eg.score->>'a')::integer then 1
        else 0
      end), 0)::integer as losses,
      coalesce(sum(case
        when eg.score is null then 0
        when eg.in_a then (eg.score->>'a')::integer
        else (eg.score->>'b')::integer
      end), 0)::integer as points_for,
      coalesce(sum(case
        when eg.score is null then 0
        when eg.in_a then (eg.score->>'b')::integer
        else (eg.score->>'a')::integer
      end), 0)::integer as points_against
    from enriched_games eg
  ),
  partner_rows as (
    select
      pl.player_name as partner_name,
      count(*)::integer as count,
      coalesce(sum(case
        when eg.score is null then 0
        when eg.in_a and (eg.score->>'a')::integer > (eg.score->>'b')::integer then 1
        when not eg.in_a and (eg.score->>'b')::integer > (eg.score->>'a')::integer then 1
        else 0
      end), 0)::integer as wins,
      coalesce(sum(case
        when eg.score is null then 0
        when eg.in_a and (eg.score->>'a')::integer < (eg.score->>'b')::integer then 1
        when not eg.in_a and (eg.score->>'b')::integer < (eg.score->>'a')::integer then 1
        else 0
      end), 0)::integer as losses
    from enriched_games eg
    cross join lateral jsonb_array_elements_text(
      case when eg.in_a then coalesce(eg.game->'teamA', '[]'::jsonb)
           else coalesce(eg.game->'teamB', '[]'::jsonb)
      end
    ) as teammate(pid)
    join player_lookup pl
      on pl.session_id = eg.session_id
     and pl.player_id = teammate.pid
    where teammate.pid <> eg.player_id
    group by pl.player_name
    order by count desc, lower(pl.player_name)
    limit 5
  ),
  opponent_rows as (
    select
      pl.player_name as opponent_name,
      count(*)::integer as count,
      coalesce(sum(case
        when eg.score is null then 0
        when eg.in_a and (eg.score->>'a')::integer > (eg.score->>'b')::integer then 1
        when not eg.in_a and (eg.score->>'b')::integer > (eg.score->>'a')::integer then 1
        else 0
      end), 0)::integer as wins,
      coalesce(sum(case
        when eg.score is null then 0
        when eg.in_a and (eg.score->>'a')::integer < (eg.score->>'b')::integer then 1
        when not eg.in_a and (eg.score->>'b')::integer < (eg.score->>'a')::integer then 1
        else 0
      end), 0)::integer as losses
    from enriched_games eg
    cross join lateral jsonb_array_elements_text(
      case when eg.in_a then coalesce(eg.game->'teamB', '[]'::jsonb)
           else coalesce(eg.game->'teamA', '[]'::jsonb)
      end
    ) as opponent(pid)
    join player_lookup pl
      on pl.session_id = eg.session_id
     and pl.player_id = opponent.pid
    group by pl.player_name
    order by count desc, lower(pl.player_name)
    limit 5
  )
  select
    coalesce((select player_name from target_players limit 1), p_name),
    coalesce((select games_played from base_stats), 0),
    coalesce((select wins from base_stats), 0),
    coalesce((select losses from base_stats), 0),
    coalesce((select points_for from base_stats), 0),
    coalesce((select points_against from base_stats), 0),
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
    v_resolved_name,
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

create or replace function public.bm_publish_tournament(p_id text, p_snapshot jsonb)
returns void
language plpgsql
security definer
set search_path = public, badminton_match
as $$
declare
  v_name text;
  v_event_date date;
begin
  v_name := coalesce(p_snapshot->>'name', p_id);
  v_event_date := coalesce((p_snapshot->>'date')::date, current_date);

  insert into badminton_match.tournaments (
    id,
    name,
    event_date,
    snapshot,
    updated_at
  )
  values (
    p_id,
    v_name,
    v_event_date,
    p_snapshot,
    now()
  )
  on conflict (id) do update
    set name = excluded.name,
        event_date = excluded.event_date,
        snapshot = excluded.snapshot,
        updated_at = now();
end;
$$;

create or replace function public.bm_get_tournament(p_id text)
returns jsonb
language sql
security definer
set search_path = public, badminton_match
as $$
  select t.snapshot
  from badminton_match.tournaments t
  where t.id = p_id;
$$;

grant usage on schema badminton_match to postgres, anon, authenticated, service_role;
grant select, insert, update, delete on all tables in schema badminton_match to postgres, service_role;
grant execute on function public.bm_publish_session(text, jsonb) to anon, authenticated, service_role;
grant execute on function public.bm_get_session(text) to anon, authenticated, service_role;
grant execute on function public.bm_list_sessions() to anon, authenticated, service_role;
grant execute on function public.bm_list_players() to anon, authenticated, service_role;
grant execute on function public.bm_get_player_stats(text) to anon, authenticated, service_role;
grant execute on function public.bm_publish_tournament(text, jsonb) to anon, authenticated, service_role;
grant execute on function public.bm_get_tournament(text) to anon, authenticated, service_role;
