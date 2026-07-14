-- Add lock status to list_sessions RPC
--
-- Returns locked=true when session status is not 'draft'.

drop function if exists bm.list_sessions();

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
