create or replace function bm.publish_tournament(p_id text, p_snapshot jsonb)
returns jsonb
language plpgsql
security definer
set search_path = bm, public
as $$
declare
  v_lookup text := trim(coalesce(p_id, ''));
  v_id text := v_lookup;
  v_share_id text := v_lookup;
  v_internal_id uuid := gen_random_uuid();
  v_name text := coalesce(p_snapshot->>'name', p_id);
  v_event_date date := coalesce(nullif(p_snapshot->>'date', '')::date, current_date);
  v_expected_version integer := nullif(p_snapshot->>'version', '')::integer;
  v_current_version integer;
  v_next_version integer := 1;
begin
  if v_lookup = '' then
    raise exception 'tournament id must not be blank';
  end if;

  perform bm.validate_tournament_snapshot(p_snapshot);

  if not pg_try_advisory_xact_lock(hashtextextended(format('bm.publish_tournament:%s', v_lookup), 0)) then
    raise exception 'tournament is being updated by another request; reload and retry';
  end if;

  begin
    select t.id, t.share_id, t.internal_id, t.version
    into v_id, v_share_id, v_internal_id, v_current_version
    from bm.tournaments t
    where t.id = v_lookup
       or t.share_id = v_lookup
       or t.internal_id::text = v_lookup
    order by
      (t.id = v_lookup) desc,
      (t.share_id = v_lookup) desc
    for update nowait;
  exception
    when lock_not_available then
      raise exception 'tournament is being updated by another request; reload and retry';
  end;

  if found then
    if v_expected_version is not null and v_expected_version <> v_current_version then
      raise exception 'tournament version mismatch: expected %, actual %', v_expected_version, v_current_version;
    end if;

    v_next_version := v_current_version + 1;
  elsif v_expected_version is not null then
    raise exception 'tournament version mismatch: expected %, actual null', v_expected_version;
  end if;

  insert into bm.tournaments (
    id,
    internal_id,
    share_id,
    name,
    event_date,
    snapshot,
    version,
    updated_at
  )
  values (
    v_id,
    v_internal_id,
    v_share_id,
    v_name,
    v_event_date,
    p_snapshot - 'version',
    v_next_version,
    now()
  )
  on conflict (id) do update
    set share_id = excluded.share_id,
        name = excluded.name,
        event_date = excluded.event_date,
        snapshot = excluded.snapshot,
        version = excluded.version,
        updated_at = now();

  return bm.get_tournament(v_id);
end;
$$;

grant execute on function bm.publish_tournament(text, jsonb) to anon, authenticated, service_role;
