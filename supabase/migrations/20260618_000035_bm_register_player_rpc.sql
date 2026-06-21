-- Scope 3: Public player registration RPC
--
-- Allows anon/authenticated clients to register new canonical players
-- and register aliases (merge case). Previously ensure_player and
-- register_player_alias were service_role-only, which blocked the app
-- from publishing sessions containing new player names.
--
-- The new bm.register_player function wraps ensure_player + alias
-- registration with input validation. It is idempotent: calling with
-- a name that already resolves returns the existing player_id.

create or replace function bm.register_player(
  p_name text,
  p_canonical_name text default null
)
returns uuid
language plpgsql
security definer
set search_path = bm, public
as $$
declare
  v_alias_name text := bm.normalize_player_name(p_name);
  v_canonical text := coalesce(bm.normalize_player_name(p_canonical_name), v_alias_name);
  v_player_id uuid;
begin
  if v_alias_name is null then
    raise exception 'player name must not be blank';
  end if;

  -- If alias already exists, return the existing player (idempotent)
  select player_id into v_player_id
  from bm.player_aliases
  where alias_name = v_alias_name;

  if found then
    return v_player_id;
  end if;

  -- Ensure the canonical player exists (creates if not)
  v_player_id := bm.ensure_player(v_canonical);

  -- Register the alias
  insert into bm.player_aliases (alias_name, player_id)
  values (v_alias_name, v_player_id)
  on conflict (alias_name) do nothing;

  return v_player_id;
end;
$$;

grant execute on function bm.register_player(text, text) to anon, authenticated, service_role;
