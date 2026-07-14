-- Fix register_player TOCTOU race condition
--
-- The previous implementation (migration 000039) had a check-then-act
-- race condition:
--   1. SELECT alias → not found
--   2. resolve/create player → v_player_id
--   3. INSERT alias ON CONFLICT DO NOTHING
--   4. RETURN v_player_id   ← may be wrong if another request won the race
--
-- Two concurrent requests for the same new alias could both pass step 1,
-- each create a different player, then one wins the INSERT while the
-- other silently skips (ON CONFLICT DO NOTHING) but still returns its
-- own locally-computed player_id — pointing to a player that does NOT
-- own the alias.
--
-- Fix: after the INSERT, re-query bm.player_aliases to return the
-- actual owner of the alias. This is safe regardless of who won the
-- race.

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
  v_canonical_input text := coalesce(nullif(trim(coalesce(p_canonical_name, '')), ''), p_name);
  v_canonical_norm text := bm.normalize_player_name(v_canonical_input);
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

  -- When canonical name provided (merge case), try to resolve existing
  -- player via normalized alias lookup. This finds "Fredi" even if the
  -- caller passes "fredi", "FREDI", " Fredi ", etc.
  if v_canonical_norm is not null then
    select pa.player_id into v_player_id
    from bm.player_aliases pa
    where pa.alias_name = v_canonical_norm;
  end if;

  -- If not resolved, create new player with ORIGINAL case preserved
  if v_player_id is null then
    v_player_id := bm.ensure_player(v_canonical_input);
  end if;

  -- Register the alias (normalized for case-insensitive matching)
  insert into bm.player_aliases (alias_name, player_id)
  values (v_alias_name, v_player_id)
  on conflict (alias_name) do nothing;

  -- Re-query to get the actual alias owner (handles race condition).
  -- If a concurrent request won the INSERT race, this returns THEIR
  -- player_id instead of our stale local value.
  select pa.player_id into v_player_id
  from bm.player_aliases pa
  where pa.alias_name = v_alias_name;

  return v_player_id;
end;
$$;

grant execute on function bm.register_player(text, text) to anon, authenticated, service_role;
