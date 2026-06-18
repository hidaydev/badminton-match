alter table bm.sessions
  add column if not exists internal_id uuid;

update bm.sessions
set internal_id = gen_random_uuid()
where internal_id is null;

alter table bm.sessions
  alter column internal_id set default gen_random_uuid();

alter table bm.sessions
  alter column internal_id set not null;

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname = 'bm_sessions_internal_id_key'
      and conrelid = 'bm.sessions'::regclass
  ) then
    alter table bm.sessions
      add constraint bm_sessions_internal_id_key unique (internal_id);
  end if;
end
$$;

alter table bm.sessions
  add column if not exists share_id text;

update bm.sessions
set share_id = id
where share_id is null;

alter table bm.sessions
  alter column share_id set not null;

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname = 'bm_sessions_share_id_key'
      and conrelid = 'bm.sessions'::regclass
  ) then
    alter table bm.sessions
      add constraint bm_sessions_share_id_key unique (share_id);
  end if;
end
$$;

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname = 'bm_sessions_share_id_not_blank_ck'
      and conrelid = 'bm.sessions'::regclass
  ) then
    alter table bm.sessions
      add constraint bm_sessions_share_id_not_blank_ck
      check (trim(share_id) <> '');
  end if;
end
$$;

create index if not exists bm_sessions_share_id_idx
  on bm.sessions (share_id);

alter table bm.tournaments
  add column if not exists internal_id uuid;

update bm.tournaments
set internal_id = gen_random_uuid()
where internal_id is null;

alter table bm.tournaments
  alter column internal_id set default gen_random_uuid();

alter table bm.tournaments
  alter column internal_id set not null;

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname = 'bm_tournaments_internal_id_key'
      and conrelid = 'bm.tournaments'::regclass
  ) then
    alter table bm.tournaments
      add constraint bm_tournaments_internal_id_key unique (internal_id);
  end if;
end
$$;

alter table bm.tournaments
  add column if not exists share_id text;

update bm.tournaments
set share_id = id
where share_id is null;

alter table bm.tournaments
  alter column share_id set not null;

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname = 'bm_tournaments_share_id_key'
      and conrelid = 'bm.tournaments'::regclass
  ) then
    alter table bm.tournaments
      add constraint bm_tournaments_share_id_key unique (share_id);
  end if;
end
$$;

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname = 'bm_tournaments_share_id_not_blank_ck'
      and conrelid = 'bm.tournaments'::regclass
  ) then
    alter table bm.tournaments
      add constraint bm_tournaments_share_id_not_blank_ck
      check (trim(share_id) <> '');
  end if;
end
$$;

create index if not exists bm_tournaments_share_id_idx
  on bm.tournaments (share_id);

alter table bm.tournaments
  add column if not exists version integer;

update bm.tournaments
set version = 1
where version is null;

alter table bm.tournaments
  alter column version set default 1;

alter table bm.tournaments
  alter column version set not null;

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname = 'bm_tournaments_version_positive_ck'
      and conrelid = 'bm.tournaments'::regclass
  ) then
    alter table bm.tournaments
      add constraint bm_tournaments_version_positive_ck
      check (version > 0);
  end if;
end
$$;

drop function if exists public.bm_publish_tournament(text, jsonb);
drop function if exists bm.publish_tournament(text, jsonb);

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

  if p_snapshot is null then
    raise exception 'tournament snapshot must not be null';
  end if;

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

create or replace function bm.get_tournament(p_id text)
returns jsonb
language sql
security definer
set search_path = bm, public
as $$
  select t.snapshot || jsonb_build_object('version', t.version)
  from bm.tournaments t
  where t.id = p_id;
$$;

grant execute on function bm.publish_tournament(text, jsonb) to anon, authenticated, service_role;
grant execute on function bm.get_tournament(text) to anon, authenticated, service_role;

create or replace function public.bm_publish_tournament(p_id text, p_snapshot jsonb)
returns void
language plpgsql
security definer
set search_path = public, bm
as $$
begin
  perform bm.publish_tournament(p_id, p_snapshot);
end;
$$;

grant execute on function public.bm_publish_tournament(text, jsonb) to anon, authenticated, service_role;
