do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname = 'bm_tournaments_snapshot_object_ck'
      and conrelid = 'bm.tournaments'::regclass
  ) then
    alter table bm.tournaments
      add constraint bm_tournaments_snapshot_object_ck
      check (jsonb_typeof(snapshot) = 'object');
  end if;
end
$$;

create or replace function bm.validate_tournament_snapshot(p_snapshot jsonb)
returns void
language plpgsql
security definer
set search_path = bm, public
as $$
declare
  v_pair_count integer;
  v_group_count integer;
  v_match_count integer;
begin
  if p_snapshot is null then
    raise exception 'tournament snapshot must not be null';
  end if;

  if jsonb_typeof(p_snapshot) <> 'object' then
    raise exception 'tournament snapshot must be a json object';
  end if;

  if trim(coalesce(p_snapshot->>'name', '')) = '' then
    raise exception 'tournament snapshot name must not be blank';
  end if;

  if coalesce(p_snapshot->>'date', '') = '' then
    raise exception 'tournament snapshot date must not be blank';
  end if;

  perform (p_snapshot->>'date')::date;

  if jsonb_typeof(coalesce(p_snapshot->'pairs', 'null'::jsonb)) <> 'array' then
    raise exception 'tournament snapshot pairs must be an array';
  end if;

  if jsonb_typeof(coalesce(p_snapshot->'groups', 'null'::jsonb)) <> 'object' then
    raise exception 'tournament snapshot groups must be an object';
  end if;

  if jsonb_typeof(coalesce(p_snapshot->'matches', 'null'::jsonb)) <> 'array' then
    raise exception 'tournament snapshot matches must be an array';
  end if;

  select count(*)
  into v_pair_count
  from jsonb_array_elements(p_snapshot->'pairs') pair_item;

  if v_pair_count <> 16 then
    raise exception 'tournament snapshot must contain exactly 16 pairs';
  end if;

  if exists (
    select 1
    from jsonb_array_elements(p_snapshot->'pairs') pair_item
    where jsonb_typeof(pair_item) <> 'object'
       or trim(coalesce(pair_item->>'id', '')) = ''
       or trim(coalesce(pair_item->>'name', '')) = ''
  ) then
    raise exception 'tournament pairs must contain non-blank id and name fields';
  end if;

  if exists (
    select 1
    from (
      select pair_item->>'id' as pair_id, count(*) as c
      from jsonb_array_elements(p_snapshot->'pairs') pair_item
      group by pair_item->>'id'
      having count(*) > 1
    ) dup_pair
  ) then
    raise exception 'tournament pair ids must be unique';
  end if;

  select count(*)
  into v_group_count
  from jsonb_object_keys(p_snapshot->'groups') group_key;

  if v_group_count <> 4 then
    raise exception 'tournament groups must contain exactly 4 keys';
  end if;

  if exists (
    select 1
    from (values ('A'), ('B'), ('C'), ('D')) as expected(group_id)
    where not ((p_snapshot->'groups') ? expected.group_id)
  ) then
    raise exception 'tournament groups must contain keys A, B, C, and D';
  end if;

  if exists (
    select 1
    from (values ('A'), ('B'), ('C'), ('D')) as expected(group_id)
    where jsonb_typeof(p_snapshot->'groups'->expected.group_id) <> 'array'
  ) then
    raise exception 'each tournament group must be an array';
  end if;

  if exists (
    select 1
    from (values ('A'), ('B'), ('C'), ('D')) as expected(group_id)
    where jsonb_array_length(p_snapshot->'groups'->expected.group_id) not in (0, 4)
  ) then
    raise exception 'each tournament group must contain either 0 or 4 pair ids';
  end if;

  if exists (
    select 1
    from (
      select jsonb_array_elements_text(p_snapshot->'groups'->'A') as pair_id
      union all
      select jsonb_array_elements_text(p_snapshot->'groups'->'B')
      union all
      select jsonb_array_elements_text(p_snapshot->'groups'->'C')
      union all
      select jsonb_array_elements_text(p_snapshot->'groups'->'D')
    ) grouped
    left join (
      select pair_item->>'id' as pair_id
      from jsonb_array_elements(p_snapshot->'pairs') pair_item
    ) pairs
      on pairs.pair_id = grouped.pair_id
    where trim(coalesce(grouped.pair_id, '')) = ''
       or pairs.pair_id is null
  ) then
    raise exception 'tournament groups must only reference known non-blank pair ids';
  end if;

  if exists (
    select 1
    from (
      select pair_id, count(*) as c
      from (
        select jsonb_array_elements_text(p_snapshot->'groups'->'A') as pair_id
        union all
        select jsonb_array_elements_text(p_snapshot->'groups'->'B')
        union all
        select jsonb_array_elements_text(p_snapshot->'groups'->'C')
        union all
        select jsonb_array_elements_text(p_snapshot->'groups'->'D')
      ) grouped
      group by pair_id
      having count(*) > 1
    ) dup_group_pair
  ) then
    raise exception 'tournament group assignments must not repeat pair ids';
  end if;

  select count(*)
  into v_match_count
  from jsonb_array_elements(p_snapshot->'matches') match_item;

  if v_match_count <> 14 then
    raise exception 'tournament snapshot must contain exactly 14 matches';
  end if;

  if exists (
    select 1
    from jsonb_array_elements(p_snapshot->'matches') match_item
    where jsonb_typeof(match_item) <> 'object'
       or trim(coalesce(match_item->>'id', '')) = ''
       or coalesce(match_item->>'phase', '') not in ('group', 'qf', 'sf', '3rd', 'final')
  ) then
    raise exception 'tournament matches must contain non-blank id and valid phase fields';
  end if;

  if exists (
    select 1
    from (
      select match_item->>'id' as match_id, count(*) as c
      from jsonb_array_elements(p_snapshot->'matches') match_item
      group by match_item->>'id'
      having count(*) > 1
    ) dup_match
  ) then
    raise exception 'tournament match ids must be unique';
  end if;

  if exists (
    select 1
    from (
      select
        trim(coalesce(match_item->>'pairAId', '')) as pair_a_id,
        trim(coalesce(match_item->>'pairBId', '')) as pair_b_id
      from jsonb_array_elements(p_snapshot->'matches') match_item
    ) match_pairs
    left join (
      select pair_item->>'id' as pair_id
      from jsonb_array_elements(p_snapshot->'pairs') pair_item
    ) pairs_a
      on pairs_a.pair_id = match_pairs.pair_a_id
    left join (
      select pair_item->>'id' as pair_id
      from jsonb_array_elements(p_snapshot->'pairs') pair_item
    ) pairs_b
      on pairs_b.pair_id = match_pairs.pair_b_id
    where (match_pairs.pair_a_id <> '' and pairs_a.pair_id is null)
       or (match_pairs.pair_b_id <> '' and pairs_b.pair_id is null)
       or (match_pairs.pair_a_id <> '' and match_pairs.pair_b_id <> '' and match_pairs.pair_a_id = match_pairs.pair_b_id)
  ) then
    raise exception 'tournament matches must reference known distinct pair ids';
  end if;
end;
$$;

grant execute on function bm.validate_tournament_snapshot(jsonb) to anon, authenticated, service_role;

create or replace function bm.publish_tournament(p_id text, p_snapshot jsonb)
returns jsonb
language plpgsql
security definer
set search_path = bm, public
as $$
declare
  v_name text := coalesce(p_snapshot->>'name', p_id);
  v_event_date date := coalesce(nullif(p_snapshot->>'date', '')::date, current_date);
  v_expected_version integer := nullif(p_snapshot->>'version', '')::integer;
  v_current_version integer;
  v_next_version integer := 1;
begin
  if trim(coalesce(p_id, '')) = '' then
    raise exception 'tournament id must not be blank';
  end if;

  perform bm.validate_tournament_snapshot(p_snapshot);

  begin
    select t.version
    into v_current_version
    from bm.tournaments t
    where t.id = p_id
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
    share_id,
    name,
    event_date,
    snapshot,
    version,
    updated_at
  )
  values (
    p_id,
    p_id,
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

  return bm.get_tournament(p_id);
end;
$$;

grant execute on function bm.publish_tournament(text, jsonb) to anon, authenticated, service_role;
