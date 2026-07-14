-- Fix H2+H3: delete_session lock check + Fix M5: public.bm_list_sessions wrapper
--
-- H2+H3: bm.delete_session now rejects deletion of non-draft sessions.
--   Prevents accidental deletion of locked/published sessions.
--   Only service_role can call this function (existing grant), but even
--   service_role must unlock first unless using raw SQL.
--
-- M5: public.bm_list_sessions wrapper now includes the `locked` column
--   that was added to bm.list_sessions in migration 000048.

-- ──────────────────────────────────────────────────────────────────────
-- H2+H3: bm.delete_session — add lock status check
-- ──────────────────────────────────────────────────────────────────────

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
  v_status text;
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

  -- Check if session is locked (non-draft status)
  select s.status into v_status
  from bm.sessions s
  where s.internal_id = v_internal_id;

  if v_status <> 'draft' then
    raise exception 'cannot delete a locked session; unlock it first or use service_role';
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

-- ──────────────────────────────────────────────────────────────────────
-- M5: public.bm_list_sessions — add locked column to match bm.list_sessions
-- ──────────────────────────────────────────────────────────────────────

create or replace function public.bm_list_sessions()
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
  select * from bm.list_sessions();
$$;

grant execute on function public.bm_list_sessions() to anon, authenticated, service_role;
