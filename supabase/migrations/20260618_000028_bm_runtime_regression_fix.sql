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

grant execute on function bm.resolve_session_lookup(text) to anon, authenticated, service_role;
grant execute on function bm.resolve_tournament_lookup(text) to anon, authenticated, service_role;
grant execute on function bm.get_session_snapshot_compat(text) to anon, authenticated, service_role;
grant execute on function bm.get_player_stats_compat(text) to anon, authenticated, service_role;
grant execute on function bm.validate_session_snapshot(jsonb) to anon, authenticated, service_role;
grant execute on function bm.validate_tournament_snapshot(jsonb) to anon, authenticated, service_role;
