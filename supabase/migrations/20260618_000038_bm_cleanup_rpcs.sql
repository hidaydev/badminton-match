-- Manual cleanup RPCs: delete_session and delete_player
--
-- These are operational/maintenance functions for manual use via Supabase
-- SQL Editor. They are NOT exposed to anon/authenticated — only service_role
-- (and implicitly postgres/superuser). Intended for cleaning up test data.
--
-- Session deletion: cascades handle all child tables.
-- Player deletion: session_players.player_id has NO CASCADE, so must
--   handle references explicitly. p_force=true removes session_players
--   rows first (their children cascade), then aliases, then the player.

create or replace function bm.delete_session(p_lookup text)
returns jsonb
language plpgsql
security definer
set search_path = bm, public
as $$
declare
  v_session_id text;
  v_share_id text;
  v_internal_id uuid;
  v_session_count integer;
  v_court_count integer;
  v_player_count integer;
  v_fix_count integer;
  v_game_count integer;
begin
  if trim(coalesce(p_lookup, '')) = '' then
    raise exception 'session lookup must not be blank';
  end if;

  -- Resolve by id, share_id, or internal_id
  select s.id, s.share_id, s.internal_id
  into v_session_id, v_share_id, v_internal_id
  from bm.sessions s
  where s.id = p_lookup
     or s.share_id = p_lookup
     or s.internal_id::text = p_lookup
  order by
    (s.id = p_lookup) desc,
    (s.share_id = p_lookup) desc;

  if not found then
    raise exception 'session not found: %', p_lookup;
  end if;

  -- Count what will be deleted (for the return summary)
  select count(*) into v_court_count from bm.session_courts where session_internal_id = v_internal_id;
  select count(*) into v_player_count from bm.session_players where session_internal_id = v_internal_id;
  select count(*) into v_fix_count from bm.fix_matches where session_internal_id = v_internal_id;
  select count(*) into v_game_count from bm.scheduled_games where session_internal_id = v_internal_id;

  -- Delete the session row — cascades handle all children:
  --   session_courts, session_players, fix_matches (→ fix_match_slots),
  --   scheduled_games (→ scheduled_game_players, game_progress, game_scores)
  delete from bm.sessions where internal_id = v_internal_id;

  return jsonb_build_object(
    'deleted', true,
    'sessionId', v_session_id,
    'shareId', v_share_id,
    'internalId', v_internal_id,
    'courts', v_court_count,
    'players', v_player_count,
    'fixMatches', v_fix_count,
    'games', v_game_count
  );
end;
$$;

grant execute on function bm.delete_session(text) to service_role;
revoke execute on function bm.delete_session(text) from anon, authenticated;

create or replace function bm.delete_player(
  p_name text,
  p_force boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path = bm, public
as $$
declare
  v_normalized text := bm.normalize_player_name(p_name);
  v_player_id uuid;
  v_canonical text;
  v_alias_count integer;
  v_session_ref_count integer;
  v_session_refs jsonb;
begin
  if v_normalized is null then
    raise exception 'player name must not be blank';
  end if;

  -- Resolve player via alias
  select pa.player_id into v_player_id
  from bm.player_aliases pa
  where pa.alias_name = v_normalized;

  if v_player_id is null then
    raise exception 'player not found: %', p_name;
  end if;

  select canonical_name into v_canonical
  from bm.players where id = v_player_id;

  -- Check session_players references
  select count(*) into v_session_ref_count
  from bm.session_players where player_id = v_player_id;

  if v_session_ref_count > 0 and not p_force then
    select coalesce(jsonb_agg(jsonb_build_object(
      'sessionId', sp.session_id,
      'sourceName', sp.source_name
    ) order by sp.session_id), '[]'::jsonb)
    into v_session_refs
    from bm.session_players sp
    where sp.player_id = v_player_id;

    raise exception
      'player % is referenced in % session(s). Use p_force=true to remove. References: %',
      v_canonical, v_session_ref_count, v_session_refs::text;
  end if;

  -- Count aliases for summary
  select count(*) into v_alias_count from bm.player_aliases where player_id = v_player_id;

  -- If forced: delete session_players rows first.
  -- Cascade handles: fix_match_slots (SET NULL), scheduled_game_players (CASCADE)
  if v_session_ref_count > 0 then
    delete from bm.session_players where player_id = v_player_id;
  end if;

  -- Delete aliases (ON DELETE CASCADE from bm.players, but do explicitly for clarity)
  delete from bm.player_aliases where player_id = v_player_id;

  -- Delete the player
  delete from bm.players where id = v_player_id;

  return jsonb_build_object(
    'deleted', true,
    'playerId', v_player_id,
    'canonicalName', v_canonical,
    'aliases', v_alias_count,
    'sessionRefsRemoved', v_session_ref_count
  );
end;
$$;

grant execute on function bm.delete_player(text, boolean) to service_role;
revoke execute on function bm.delete_player(text, boolean) from anon, authenticated;
