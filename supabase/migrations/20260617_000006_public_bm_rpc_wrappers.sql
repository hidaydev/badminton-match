-- Compatibility-only wrapper surface.
-- These functions exist so older/public clients can call familiar RPC names.
-- The intended local app runtime for this branch is direct `bm.*` access via
-- PostgREST profile headers, not these wrappers.

create or replace function public.bm_get_session(p_id text)
returns jsonb
language sql
security definer
set search_path = public, bm
as $$
  select bm.get_session(p_id);
$$;

create or replace function public.bm_publish_session(p_id text, p_snapshot jsonb)
returns void
language sql
security definer
set search_path = public, bm
as $$
  select bm.publish_session(p_id, p_snapshot);
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
set search_path = public, bm
as $$
  select *
  from bm.list_sessions();
$$;

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

create or replace function public.bm_get_player_stats(p_name text)
returns jsonb
language sql
security definer
set search_path = public, bm
as $$
  select bm.get_player_stats(p_name);
$$;

create or replace function public.bm_get_tournament(p_id text)
returns jsonb
language sql
security definer
set search_path = public, bm
as $$
  select bm.get_tournament(p_id);
$$;

create or replace function public.bm_publish_tournament(p_id text, p_snapshot jsonb)
returns void
language sql
security definer
set search_path = public, bm
as $$
  select bm.publish_tournament(p_id, p_snapshot);
$$;

grant execute on function public.bm_get_session(text) to anon, authenticated, service_role;
grant execute on function public.bm_publish_session(text, jsonb) to anon, authenticated, service_role;
grant execute on function public.bm_list_sessions() to anon, authenticated, service_role;
grant execute on function public.bm_list_players() to anon, authenticated, service_role;
grant execute on function public.bm_get_player_stats(text) to anon, authenticated, service_role;
grant execute on function public.bm_get_tournament(text) to anon, authenticated, service_role;
grant execute on function public.bm_publish_tournament(text, jsonb) to anon, authenticated, service_role;
