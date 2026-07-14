-- Fix unlock_session: add advisory lock + check lock state
--
-- Previous version had no concurrency protection and didn't verify
-- the session was actually locked before unlocking.

create or replace function bm.unlock_session(p_id text)
returns jsonb
language plpgsql
security definer
set search_path = bm, public
as $$
declare
  v_lookup text := trim(coalesce(p_id, ''));
  v_internal_id uuid;
  v_current_status text;
begin
  if v_lookup = '' then
    raise exception 'session id must not be blank';
  end if;

  -- Advisory lock for mutual exclusion
  if not pg_try_advisory_xact_lock(hashtextextended(format('bm.unlock_session:%s', v_lookup), 0)) then
    raise exception 'session is being updated by another request; reload and retry';
  end if;

  select s.internal_id, s.status into v_internal_id, v_current_status
  from bm.sessions s
  where s.id = v_lookup
     or s.share_id = v_lookup
     or s.internal_id::text = v_lookup
  for update nowait;

  if v_internal_id is null then
    raise exception 'session not found: %', v_lookup;
  end if;

  -- Only unlock if actually locked
  if v_current_status = 'draft' then
    return bm.get_session(v_lookup);
  end if;

  -- Clear the lock by setting status back to draft
  update bm.sessions
  set status = 'draft',
      updated_at = now()
  where internal_id = v_internal_id;

  return bm.get_session(v_lookup);
exception
  when lock_not_available then
    raise exception 'session is being updated by another request; reload and retry';
end;
$$;

-- Admin only — not exposed to anon or authenticated
grant execute on function bm.unlock_session(text) to service_role;
revoke execute on function bm.unlock_session(text) from anon, authenticated;
