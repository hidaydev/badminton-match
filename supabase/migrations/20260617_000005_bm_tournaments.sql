create table if not exists bm.tournaments (
  id text primary key,
  name text not null default '',
  event_date date not null default current_date,
  snapshot jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now(),
  constraint bm_tournaments_id_not_blank_ck check (trim(id) <> '')
);

create or replace function bm.publish_tournament(p_id text, p_snapshot jsonb)
returns void
language plpgsql
security definer
set search_path = bm, public
as $$
declare
  v_name text := coalesce(p_snapshot->>'name', p_id);
  v_event_date date := coalesce(nullif(p_snapshot->>'date', '')::date, current_date);
begin
  if trim(coalesce(p_id, '')) = '' then
    raise exception 'tournament id must not be blank';
  end if;

  if p_snapshot is null then
    raise exception 'tournament snapshot must not be null';
  end if;

  insert into bm.tournaments (
    id,
    name,
    event_date,
    snapshot,
    updated_at
  )
  values (
    p_id,
    v_name,
    v_event_date,
    p_snapshot,
    now()
  )
  on conflict (id) do update
    set name = excluded.name,
        event_date = excluded.event_date,
        snapshot = excluded.snapshot,
        updated_at = now();
end;
$$;

create or replace function bm.get_tournament(p_id text)
returns jsonb
language sql
security definer
set search_path = bm, public
as $$
  select t.snapshot
  from bm.tournaments t
  where t.id = p_id;
$$;

grant execute on function bm.publish_tournament(text, jsonb) to anon, authenticated, service_role;
grant execute on function bm.get_tournament(text) to anon, authenticated, service_role;
