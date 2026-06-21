-- Fix delete_player: use player_id (uuid) instead of name to avoid ambiguous resolution
--
-- Previous version accepted a name and resolved via player_aliases lookup.
-- This was ambiguous when duplicate players existed (e.g., bug from migration
-- 000035 created both 'Fredi' and 'fredi'). Calling delete_player('fredi')
-- resolved to whichever player had 'fredi' as an alias — which was the
-- ORIGINAL 'Fredi', not the duplicate 'fredi'.
--
-- Now accepts p_player_id uuid directly. Since player_aliases has
-- ON DELETE CASCADE, deleting from bm.players auto-removes aliases.
-- Only session_players needs explicit handling (no cascade on FK).

drop function if exists bm.delete_player(text, boolean);

create or replace function bm.delete_player(
  p_player_id uuid,
  p_force boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path = bm, public
as $$
declare
  v_canonical text;
  v_alias_count integer;
  v_session_ref_count integer;
  v_session_refs jsonb;
begin
  -- Verify player exists
  select canonical_name into v_canonical
  from bm.players where id = p_player_id;

  if not found then
    raise exception 'player not found: %', p_player_id;
  end if;

  -- Check session_players references (FK has no cascade)
  select count(*) into v_session_ref_count
  from bm.session_players where player_id = p_player_id;

  if v_session_ref_count > 0 and not p_force then
    select coalesce(jsonb_agg(jsonb_build_object(
      'sessionId', sp.session_id,
      'sourceName', sp.source_name
    ) order by sp.session_id), '[]'::jsonb)
    into v_session_refs
    from bm.session_players sp
    where sp.player_id = p_player_id;

    raise exception
      'player % is referenced in % session(s). Use p_force=true to remove. References: %',
      v_canonical, v_session_ref_count, v_session_refs::text;
  end if;

  -- Count aliases for summary (before cascade deletes them)
  select count(*) into v_alias_count from bm.player_aliases where player_id = p_player_id;

  -- Force: remove session_players rows first
  -- (cascade handles: fix_match_slots SET NULL, scheduled_game_players CASCADE)
  if v_session_ref_count > 0 then
    delete from bm.session_players where player_id = p_player_id;
  end if;

  -- Delete the player — ON DELETE CASCADE auto-removes player_aliases
  delete from bm.players where id = p_player_id;

  return jsonb_build_object(
    'deleted', true,
    'playerId', p_player_id,
    'canonicalName', v_canonical,
    'aliases', v_alias_count,
    'sessionRefsRemoved', v_session_ref_count
  );
end;
$$;

grant execute on function bm.delete_player(uuid, boolean) to service_role;
revoke execute on function bm.delete_player(uuid, boolean) from anon, authenticated;
