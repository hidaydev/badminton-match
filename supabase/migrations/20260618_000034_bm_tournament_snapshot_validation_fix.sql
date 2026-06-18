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
  v_group_match_count integer;
  v_qf_count integer;
  v_sf_count integer;
  v_third_count integer;
  v_final_count integer;
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
  from jsonb_array_elements(p_snapshot->'pairs') as pair_item(value);

  if v_pair_count <> 16 then
    raise exception 'tournament snapshot must contain exactly 16 pairs';
  end if;

  if exists (
    select 1
    from jsonb_array_elements(p_snapshot->'pairs') as pair_item(value)
    where jsonb_typeof(pair_item.value) <> 'object'
       or trim(coalesce(pair_item.value->>'id', '')) = ''
       or trim(coalesce(pair_item.value->>'name', '')) = ''
  ) then
    raise exception 'tournament pairs must contain non-blank id and name fields';
  end if;

  if exists (
    select 1
    from (
      select pair_item.value->>'id' as pair_id, count(*) as c
      from jsonb_array_elements(p_snapshot->'pairs') as pair_item(value)
      group by pair_item.value->>'id'
      having count(*) > 1
    ) dup_pair
  ) then
    raise exception 'tournament pair ids must be unique';
  end if;

  select count(*)
  into v_group_count
  from jsonb_object_keys(p_snapshot->'groups') as group_key(value);

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
      select pair_item.value->>'id' as pair_id
      from jsonb_array_elements(p_snapshot->'pairs') as pair_item(value)
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

  select
    count(*)::integer,
    count(*) filter (where match_item.value->>'phase' = 'group')::integer,
    count(*) filter (where match_item.value->>'phase' = 'qf')::integer,
    count(*) filter (where match_item.value->>'phase' = 'sf')::integer,
    count(*) filter (where match_item.value->>'phase' = '3rd')::integer,
    count(*) filter (where match_item.value->>'phase' = 'final')::integer
  into
    v_match_count,
    v_group_match_count,
    v_qf_count,
    v_sf_count,
    v_third_count,
    v_final_count
  from jsonb_array_elements(p_snapshot->'matches') as match_item(value);

  if v_match_count <> 32 then
    raise exception 'tournament snapshot must contain exactly 32 matches';
  end if;

  if v_group_match_count <> 24 or v_qf_count <> 4 or v_sf_count <> 2 or v_third_count <> 1 or v_final_count <> 1 then
    raise exception 'tournament snapshot must contain 24 group matches, 4 qf, 2 sf, 1 third-place, and 1 final';
  end if;

  if exists (
    select 1
    from jsonb_array_elements(p_snapshot->'matches') as match_item(value)
    where jsonb_typeof(match_item.value) <> 'object'
       or trim(coalesce(match_item.value->>'id', '')) = ''
       or coalesce(match_item.value->>'phase', '') not in ('group', 'qf', 'sf', '3rd', 'final')
  ) then
    raise exception 'tournament matches must contain non-blank id and valid phase fields';
  end if;

  if exists (
    select 1
    from (
      select match_item.value->>'id' as match_id, count(*) as c
      from jsonb_array_elements(p_snapshot->'matches') as match_item(value)
      group by match_item.value->>'id'
      having count(*) > 1
    ) dup_match
  ) then
    raise exception 'tournament match ids must be unique';
  end if;

  if exists (
    select 1
    from (
      select
        trim(coalesce(match_item.value->>'pairAId', '')) as pair_a_id,
        trim(coalesce(match_item.value->>'pairBId', '')) as pair_b_id
      from jsonb_array_elements(p_snapshot->'matches') as match_item(value)
    ) match_pairs
    left join (
      select pair_item.value->>'id' as pair_id
      from jsonb_array_elements(p_snapshot->'pairs') as pair_item(value)
    ) pairs_a
      on pairs_a.pair_id = match_pairs.pair_a_id
    left join (
      select pair_item.value->>'id' as pair_id
      from jsonb_array_elements(p_snapshot->'pairs') as pair_item(value)
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
