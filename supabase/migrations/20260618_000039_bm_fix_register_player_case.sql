-- Fix register_player: preserve canonical name case and resolve existing player via alias
--
-- Migration 000035 had two bugs:
-- 1. normalize_player_name(p_canonical_name) lowercased the canonical name
--    before passing to ensure_player, which stores it as-is in
--    bm.players.canonical_name. Merge "Freddie" → "Fredi" saved "fredi".
-- 2. Merge case did not resolve the existing canonical player via alias
--    lookup. ensure_player('fredi') checked canonical_name = 'fredi'
--    (case-sensitive), didn't match existing 'Fredi', created duplicate.
--
-- This migration rewrites register_player to:
-- - Preserve original case of p_canonical_name for ensure_player
-- - Resolve existing player via normalized alias lookup when merging
-- - Only create new player if canonical truly doesn't exist

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

  return v_player_id;
end;
$$;

grant execute on function bm.register_player(text, text) to anon, authenticated, service_role;
