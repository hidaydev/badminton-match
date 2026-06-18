create schema if not exists bm;

create or replace function bm.normalize_player_name(p_name text)
returns text
language sql
immutable
as $$
  select nullif(
    regexp_replace(lower(trim(coalesce(p_name, ''))), '\s+', ' ', 'g'),
    ''
  );
$$;

create or replace function bm.set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

create table if not exists bm.players (
  id uuid primary key default gen_random_uuid(),
  canonical_name text not null unique,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists bm.player_aliases (
  alias_name text primary key,
  player_id uuid not null references bm.players(id) on delete cascade,
  created_at timestamptz not null default now(),
  constraint player_aliases_alias_name_normalized_ck
    check (alias_name = bm.normalize_player_name(alias_name))
);

create index if not exists bm_player_aliases_player_id_idx
  on bm.player_aliases (player_id);

create table if not exists bm.sessions (
  id text primary key,
  title text not null default '',
  session_date date not null,
  session_start time not null default '00:00'::time,
  slot_minutes integer not null check (slot_minutes > 0),
  session_tier_count integer not null default 0 check (session_tier_count >= 0),
  include_tier_count boolean not null default false,
  include_absent_players boolean not null default false,
  status text not null check (status in ('draft', 'locked', 'published', 'completed', 'archived')),
  source text not null check (source in ('compat_publish', 'legacy_snapshot', 'manual')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists bm_sessions_session_date_idx
  on bm.sessions (session_date desc);

create index if not exists bm_sessions_updated_at_idx
  on bm.sessions (updated_at desc);

create table if not exists bm.session_courts (
  id bigserial primary key,
  session_id text not null references bm.sessions(id) on delete cascade,
  court_index integer not null check (court_index >= 0),
  court_name text not null default '',
  start_time time not null,
  end_time time not null,
  constraint bm_session_courts_session_court_key unique (session_id, court_index),
  constraint bm_session_courts_time_range_ck check (end_time > start_time)
);

create table if not exists bm.session_players (
  id bigserial primary key,
  session_id text not null references bm.sessions(id) on delete cascade,
  player_id uuid not null references bm.players(id),
  player_ref text not null,
  source_name text not null,
  sort_order integer not null default 0 check (sort_order >= 0),
  absent_order integer check (absent_order is null or absent_order >= 0),
  gender text not null check (gender in ('M', 'F')),
  tier integer not null check (tier between 1 and 4),
  is_absent boolean not null default false,
  replacement_note text not null default '',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint bm_session_players_session_player_key unique (session_id, player_id),
  constraint bm_session_players_session_player_ref_key unique (session_id, player_ref),
  constraint bm_session_players_session_sort_order_key unique (session_id, sort_order),
  constraint bm_session_players_player_ref_not_blank_ck check (trim(player_ref) <> '')
);

create index if not exists bm_session_players_player_id_idx
  on bm.session_players (player_id);

create table if not exists bm.fix_matches (
  id bigserial primary key,
  session_id text not null references bm.sessions(id) on delete cascade,
  legacy_ref text not null,
  sort_order integer not null default 0 check (sort_order >= 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint bm_fix_matches_session_legacy_ref_key unique (session_id, legacy_ref),
  constraint bm_fix_matches_session_sort_order_key unique (session_id, sort_order)
);

create table if not exists bm.fix_match_slots (
  id bigserial primary key,
  fix_match_id bigint not null references bm.fix_matches(id) on delete cascade,
  slot_index integer not null check (slot_index between 0 and 3),
  session_player_id bigint null references bm.session_players(id) on delete set null,
  constraint bm_fix_match_slots_fix_match_slot_key unique (fix_match_id, slot_index)
);

create table if not exists bm.scheduled_games (
  id bigserial primary key,
  session_id text not null references bm.sessions(id) on delete cascade,
  legacy_order integer not null check (legacy_order >= 0),
  slot_index integer not null check (slot_index >= 0),
  court_index integer not null check (court_index >= 0),
  status text not null check (status in ('scheduled', 'played', 'cancelled')),
  source text not null check (source in ('generator', 'manual', 'constraint', 'legacy_snapshot', 'compat_publish')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint bm_scheduled_games_session_slot_court_key unique (session_id, slot_index, court_index),
  constraint bm_scheduled_games_session_legacy_order_key unique (session_id, legacy_order)
);

create index if not exists bm_scheduled_games_session_id_idx
  on bm.scheduled_games (session_id);

create table if not exists bm.scheduled_game_players (
  id bigserial primary key,
  scheduled_game_id bigint not null references bm.scheduled_games(id) on delete cascade,
  session_player_id bigint not null references bm.session_players(id) on delete cascade,
  team text not null check (team in ('A', 'B')),
  position integer not null check (position in (0, 1)),
  constraint bm_scheduled_game_players_team_position_key unique (scheduled_game_id, team, position),
  constraint bm_scheduled_game_players_session_player_key unique (scheduled_game_id, session_player_id)
);

create index if not exists bm_scheduled_game_players_session_player_id_idx
  on bm.scheduled_game_players (session_player_id);

create table if not exists bm.game_progress (
  scheduled_game_id bigint primary key references bm.scheduled_games(id) on delete cascade,
  is_played boolean not null default false,
  played_order integer null check (played_order >= 0),
  updated_at timestamptz not null default now()
);

create table if not exists bm.game_scores (
  scheduled_game_id bigint primary key references bm.scheduled_games(id) on delete cascade,
  score_a integer not null check (score_a between 0 and 99),
  score_b integer not null check (score_b between 0 and 99),
  entered_at timestamptz not null default now(),
  constraint bm_game_scores_not_tied_ck check (score_a <> score_b)
);

drop trigger if exists bm_players_set_updated_at on bm.players;
create trigger bm_players_set_updated_at
before update on bm.players
for each row
execute function bm.set_updated_at();

drop trigger if exists bm_sessions_set_updated_at on bm.sessions;
create trigger bm_sessions_set_updated_at
before update on bm.sessions
for each row
execute function bm.set_updated_at();

drop trigger if exists bm_session_players_set_updated_at on bm.session_players;
create trigger bm_session_players_set_updated_at
before update on bm.session_players
for each row
execute function bm.set_updated_at();

drop trigger if exists bm_fix_matches_set_updated_at on bm.fix_matches;
create trigger bm_fix_matches_set_updated_at
before update on bm.fix_matches
for each row
execute function bm.set_updated_at();

drop trigger if exists bm_scheduled_games_set_updated_at on bm.scheduled_games;
create trigger bm_scheduled_games_set_updated_at
before update on bm.scheduled_games
for each row
execute function bm.set_updated_at();

create or replace function bm.ensure_player(p_canonical_name text)
returns uuid
language plpgsql
security definer
set search_path = bm, public
as $$
declare
  v_canonical_name text := trim(coalesce(p_canonical_name, ''));
  v_alias_name text;
  v_player_id uuid;
begin
  if v_canonical_name = '' then
    raise exception 'canonical player name must not be blank';
  end if;

  insert into bm.players (canonical_name)
  values (v_canonical_name)
  on conflict (canonical_name) do update
    set canonical_name = excluded.canonical_name,
        updated_at = now()
  returning id into v_player_id;

  v_alias_name := bm.normalize_player_name(v_canonical_name);

  insert into bm.player_aliases (alias_name, player_id)
  values (v_alias_name, v_player_id)
  on conflict (alias_name) do update
    set player_id = excluded.player_id;

  return v_player_id;
end;
$$;

create or replace function bm.register_player_alias(p_alias_name text, p_canonical_name text)
returns uuid
language plpgsql
security definer
set search_path = bm, public
as $$
declare
  v_alias_name text := bm.normalize_player_name(p_alias_name);
  v_player_id uuid;
begin
  if v_alias_name is null then
    raise exception 'player alias name must not be blank';
  end if;

  v_player_id := bm.ensure_player(p_canonical_name);

  insert into bm.player_aliases (alias_name, player_id)
  values (v_alias_name, v_player_id)
  on conflict (alias_name) do update
    set player_id = excluded.player_id;

  return v_player_id;
end;
$$;

create or replace function bm.resolve_player_id(p_name text)
returns uuid
language sql
stable
set search_path = bm, public
as $$
  select pa.player_id
  from bm.player_aliases pa
  where pa.alias_name = bm.normalize_player_name(p_name)
  limit 1;
$$;

create or replace function bm.publish_session(
  p_id text,
  p_snapshot jsonb,
  p_source text default 'compat_publish'
)
returns void
language plpgsql
security definer
set search_path = bm, badminton_match, public
as $$
declare
  v_title text := coalesce(p_snapshot->'session'->>'title', '');
  v_session_date date := coalesce(nullif(p_snapshot->'session'->>'date', '')::date, current_date);
  v_session_start time := coalesce(nullif(p_snapshot->'session'->>'sessionStart', '')::time, '00:00'::time);
  v_slot_minutes integer := coalesce(nullif(p_snapshot->'session'->>'slotMinutes', '')::integer, 20);
  v_session_tier_count integer := coalesce(nullif(p_snapshot->'session'->>'tierCount', '')::integer, 0);
  v_include_tier_count boolean := coalesce((p_snapshot->'session') ? 'tierCount', false);
  v_include_absent_players boolean := p_snapshot ? 'absentPlayers';
  v_status text := case
    when coalesce((p_snapshot->'session'->>'locked')::boolean, false) then 'published'
    else 'draft'
  end;
  v_unresolved jsonb := '[]'::jsonb;
  v_duplicate_resolution jsonb := '[]'::jsonb;
  v_invalid_refs jsonb := '[]'::jsonb;
begin
  if trim(coalesce(p_id, '')) = '' then
    raise exception 'session id must not be blank';
  end if;

  if p_snapshot is null then
    raise exception 'session snapshot must not be null';
  end if;

  if p_source not in ('compat_publish', 'legacy_snapshot', 'manual') then
    raise exception 'unsupported bm session source: %', p_source;
  end if;

  if v_slot_minutes <= 0 then
    raise exception 'slotMinutes must be positive for session %', p_id;
  end if;

  with snapshot_players as (
    select
      trim(player.value->>'id') as player_ref,
      coalesce(player.value->>'name', '') as source_name,
      bm.normalize_player_name(player.value->>'name') as normalized_name
    from jsonb_array_elements(coalesce(p_snapshot->'players', '[]'::jsonb)) with ordinality as player(value, ordinality)
  )
  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'sourceName', unresolved.source_name,
        'normalizedName', unresolved.normalized_name
      )
      order by unresolved.source_name
    ),
    '[]'::jsonb
  )
  into v_unresolved
  from (
    select distinct sp.source_name, sp.normalized_name
    from snapshot_players sp
    left join bm.player_aliases pa
      on pa.alias_name = sp.normalized_name
    where sp.normalized_name is null
       or pa.player_id is null
  ) unresolved;

  if v_unresolved <> '[]'::jsonb then
    raise exception 'bm.publish_session unresolved player names for %: %', p_id, v_unresolved::text;
  end if;

  with snapshot_players as (
    select
      trim(player.value->>'id') as player_ref
    from jsonb_array_elements(coalesce(p_snapshot->'players', '[]'::jsonb)) as player(value)
  ),
  referenced_ids as (
    select distinct nullif(trim(slot.value), '') as player_ref
    from jsonb_array_elements(coalesce(p_snapshot->'fixMatches', '[]'::jsonb)) as fm(value)
    cross join lateral jsonb_array_elements_text(coalesce(fm.value->'slots', '[]'::jsonb)) as slot(value)

    union

    select distinct nullif(trim(team_a.value), '') as player_ref
    from jsonb_array_elements(coalesce(p_snapshot->'schedule', '[]'::jsonb)) as game(value)
    cross join lateral jsonb_array_elements_text(coalesce(game.value->'teamA', '[]'::jsonb)) as team_a(value)

    union

    select distinct nullif(trim(team_b.value), '') as player_ref
    from jsonb_array_elements(coalesce(p_snapshot->'schedule', '[]'::jsonb)) as game(value)
    cross join lateral jsonb_array_elements_text(coalesce(game.value->'teamB', '[]'::jsonb)) as team_b(value)

    union

    select distinct nullif(trim(absent.value), '') as player_ref
    from jsonb_array_elements_text(coalesce(p_snapshot->'absentPlayers', '[]'::jsonb)) as absent(value)
  )
  select coalesce(
    jsonb_agg(to_jsonb(invalid.player_ref) order by invalid.player_ref),
    '[]'::jsonb
  )
  into v_invalid_refs
  from (
    select distinct rid.player_ref
    from referenced_ids rid
    left join snapshot_players sp
      on sp.player_ref = rid.player_ref
    where rid.player_ref is not null
      and sp.player_ref is null
  ) invalid;

  if v_invalid_refs <> '[]'::jsonb then
    raise exception 'bm.publish_session invalid player refs for %: %', p_id, v_invalid_refs::text;
  end if;

  with snapshot_players as (
    select
      trim(player.value->>'id') as player_ref,
      coalesce(player.value->>'name', '') as source_name,
      bm.normalize_player_name(player.value->>'name') as normalized_name
    from jsonb_array_elements(coalesce(p_snapshot->'players', '[]'::jsonb)) as player(value)
  ),
  resolved_players as (
    select
      sp.player_ref,
      sp.source_name,
      pa.player_id
    from snapshot_players sp
    join bm.player_aliases pa
      on pa.alias_name = sp.normalized_name
  )
  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'canonicalName', duplicates.canonical_name,
        'sourceNames', duplicates.source_names
      )
      order by duplicates.canonical_name
    ),
    '[]'::jsonb
  )
  into v_duplicate_resolution
  from (
    select
      p.canonical_name,
      jsonb_agg(rp.source_name order by rp.source_name) as source_names
    from resolved_players rp
    join bm.players p
      on p.id = rp.player_id
    group by p.id, p.canonical_name
    having count(*) > 1
  ) duplicates;

  if v_duplicate_resolution <> '[]'::jsonb then
    raise exception 'bm.publish_session duplicate canonical resolution within session %: %', p_id, v_duplicate_resolution::text;
  end if;

  delete from bm.sessions where id = p_id;

  insert into bm.sessions (
    id,
    title,
    session_date,
    session_start,
    slot_minutes,
    session_tier_count,
    include_tier_count,
    include_absent_players,
    status,
    source
  )
  values (
    p_id,
    v_title,
    v_session_date,
    v_session_start,
    v_slot_minutes,
    v_session_tier_count,
    v_include_tier_count,
    v_include_absent_players,
    v_status,
    p_source
  );

  with court_indices as (
    select generate_series(
      0,
      greatest(
        coalesce(nullif(p_snapshot->'session'->>'courts', '')::integer, 0),
        coalesce(jsonb_array_length(coalesce(p_snapshot->'session'->'courtTimes', '[]'::jsonb)), 0)
      ) - 1
    ) as court_index
  )
  insert into bm.session_courts (
    session_id,
    court_index,
    court_name,
    start_time,
    end_time
  )
  select
    p_id,
    ci.court_index,
    coalesce(p_snapshot->'session'->'courtNames'->>ci.court_index, ''),
    coalesce(
      nullif(p_snapshot->'session'->'courtTimes'->ci.court_index->>'start', '')::time,
      v_session_start
    ),
    coalesce(
      nullif(p_snapshot->'session'->'courtTimes'->ci.court_index->>'end', '')::time,
      v_session_start + make_interval(
        mins => v_slot_minutes * greatest(
          coalesce(nullif(p_snapshot->'session'->'slotsPerCourt'->>ci.court_index, '')::integer, 1),
          1
        )
      )
    )
  from court_indices ci;

  with snapshot_players as (
    select
      trim(player.value->>'id') as player_ref,
      coalesce(player.value->>'name', '') as source_name,
      bm.normalize_player_name(player.value->>'name') as normalized_name,
      coalesce(nullif(player.value->>'gender', ''), 'M') as gender,
      coalesce(nullif(player.value->>'tier', '')::integer, 1) as tier,
      player.ordinality - 1 as sort_order
    from jsonb_array_elements(coalesce(p_snapshot->'players', '[]'::jsonb)) with ordinality as player(value, ordinality)
  ),
  absent_players as (
    select
      nullif(trim(absent.value), '') as player_ref,
      absent.ordinality - 1 as absent_order
    from jsonb_array_elements_text(coalesce(p_snapshot->'absentPlayers', '[]'::jsonb)) with ordinality as absent(value, ordinality)
    where nullif(trim(absent.value), '') is not null
  ),
  resolved_players as (
    select
      sp.player_ref,
      sp.source_name,
      sp.gender,
      sp.tier,
      sp.sort_order,
      ap.absent_order,
      pa.player_id
    from snapshot_players sp
    join bm.player_aliases pa
      on pa.alias_name = sp.normalized_name
    left join absent_players ap
      on ap.player_ref = sp.player_ref
  )
  insert into bm.session_players (
    session_id,
    player_id,
    player_ref,
    source_name,
    sort_order,
    absent_order,
    gender,
    tier,
    is_absent
  )
  select
    p_id,
    rp.player_id,
    rp.player_ref,
    rp.source_name,
    rp.sort_order,
    rp.absent_order,
    rp.gender,
    rp.tier,
    rp.absent_order is not null
  from resolved_players rp
  order by rp.sort_order;

  with raw_fix_matches as (
    select
      coalesce(nullif(fm.value->>'id', ''), format('fix-%s', fm.ordinality - 1)) as legacy_ref,
      fm.ordinality - 1 as sort_order
    from jsonb_array_elements(coalesce(p_snapshot->'fixMatches', '[]'::jsonb)) with ordinality as fm(value, ordinality)
  )
  insert into bm.fix_matches (
    session_id,
    legacy_ref,
    sort_order
  )
  select
    p_id,
    rfm.legacy_ref,
    rfm.sort_order
  from raw_fix_matches rfm
  order by rfm.sort_order;

  with raw_fix_matches as (
    select
      coalesce(nullif(fm.value->>'id', ''), format('fix-%s', fm.ordinality - 1)) as legacy_ref,
      coalesce(fm.value->'slots', '[]'::jsonb) as slots_json
    from jsonb_array_elements(coalesce(p_snapshot->'fixMatches', '[]'::jsonb)) with ordinality as fm(value, ordinality)
  ),
  raw_slots as (
    select
      rfm.legacy_ref,
      slot.ordinality - 1 as slot_index,
      nullif(trim(slot.value), '') as player_ref
    from raw_fix_matches rfm
    cross join lateral jsonb_array_elements_text(rfm.slots_json) with ordinality as slot(value, ordinality)
  )
  insert into bm.fix_match_slots (
    fix_match_id,
    slot_index,
    session_player_id
  )
  select
    fm.id,
    rs.slot_index,
    sp.id
  from raw_slots rs
  join bm.fix_matches fm
    on fm.session_id = p_id
   and fm.legacy_ref = rs.legacy_ref
  left join bm.session_players sp
    on sp.session_id = p_id
   and sp.player_ref = rs.player_ref
  order by fm.sort_order, rs.slot_index;

  with raw_games as (
    select
      game.ordinality - 1 as legacy_order,
      (game.value->>'slot')::integer as slot_index,
      (game.value->>'court')::integer as court_index,
      exists (
        select 1
        from jsonb_array_elements_text(coalesce(p_snapshot->'playedGames', '[]'::jsonb)) as played(value)
        where played.value = concat(game.value->>'slot', '-', game.value->>'court')
      ) as is_played
    from jsonb_array_elements(coalesce(p_snapshot->'schedule', '[]'::jsonb)) as game(value)
  )
  insert into bm.scheduled_games (
    session_id,
    legacy_order,
    slot_index,
    court_index,
    status,
    source
  )
  select
    p_id,
    rg.legacy_order,
    rg.slot_index,
    rg.court_index,
    case when rg.is_played then 'played' else 'scheduled' end,
    case when p_source = 'legacy_snapshot' then 'legacy_snapshot' else 'compat_publish' end
  from raw_games rg
  order by rg.legacy_order;

  with raw_games as (
    select
      (game.value->>'slot')::integer as slot_index,
      (game.value->>'court')::integer as court_index,
      game.value as game_json
    from jsonb_array_elements(coalesce(p_snapshot->'schedule', '[]'::jsonb)) as game(value)
  ),
  raw_game_players as (
    select
      rg.slot_index,
      rg.court_index,
      'A'::text as team,
      team_a.ordinality - 1 as position,
      trim(team_a.value) as player_ref
    from raw_games rg
    cross join lateral jsonb_array_elements_text(coalesce(rg.game_json->'teamA', '[]'::jsonb)) with ordinality as team_a(value, ordinality)

    union all

    select
      rg.slot_index,
      rg.court_index,
      'B'::text as team,
      team_b.ordinality - 1 as position,
      trim(team_b.value) as player_ref
    from raw_games rg
    cross join lateral jsonb_array_elements_text(coalesce(rg.game_json->'teamB', '[]'::jsonb)) with ordinality as team_b(value, ordinality)
  )
  insert into bm.scheduled_game_players (
    scheduled_game_id,
    session_player_id,
    team,
    position
  )
  select
    sg.id,
    sp.id,
    rgp.team,
    rgp.position
  from raw_game_players rgp
  join bm.scheduled_games sg
    on sg.session_id = p_id
   and sg.slot_index = rgp.slot_index
   and sg.court_index = rgp.court_index
  join bm.session_players sp
    on sp.session_id = p_id
   and sp.player_ref = rgp.player_ref
  order by sg.slot_index, sg.court_index, rgp.team, rgp.position;

  insert into bm.game_progress (
    scheduled_game_id,
    is_played,
    played_order
  )
  select
    sg.id,
    played.played_order is not null,
    played.played_order
  from bm.scheduled_games sg
  left join (
    select
      played.value as game_key,
      played.ordinality - 1 as played_order
    from jsonb_array_elements_text(coalesce(p_snapshot->'playedGames', '[]'::jsonb)) with ordinality as played(value, ordinality)
  ) played
    on played.game_key = concat(sg.slot_index, '-', sg.court_index)
  where sg.session_id = p_id;

  insert into bm.game_scores (
    scheduled_game_id,
    score_a,
    score_b
  )
  select
    sg.id,
    (score.value->>'a')::integer,
    (score.value->>'b')::integer
  from jsonb_each(coalesce(p_snapshot->'gameScores', '{}'::jsonb)) as score(key, value)
  join bm.scheduled_games sg
    on sg.session_id = p_id
   and concat(sg.slot_index, '-', sg.court_index) = score.key;
end;
$$;

create or replace function bm.get_session_snapshot_compat(p_id text)
returns jsonb
language sql
security definer
set search_path = bm, public
as $$
  with target_session as (
    select *
    from bm.sessions
    where id = p_id
  ),
  court_rows as (
    select
      sc.session_id,
      sc.court_index,
      sc.court_name,
      sc.start_time,
      sc.end_time,
      coalesce(game_counts.game_count, 0) as game_count
    from bm.session_courts sc
    left join (
      select
        sg.session_id,
        sg.court_index,
        count(*)::integer as game_count
      from bm.scheduled_games sg
      group by sg.session_id, sg.court_index
    ) game_counts
      on game_counts.session_id = sc.session_id
     and game_counts.court_index = sc.court_index
    where sc.session_id = p_id
  ),
  player_rows as (
    select
      sp.session_id,
      sp.sort_order,
      sp.absent_order,
      sp.player_ref,
      sp.source_name,
      sp.gender,
      sp.tier,
      sp.is_absent
    from bm.session_players sp
    where sp.session_id = p_id
  ),
  fix_match_rows as (
    select
      fm.session_id,
      fm.sort_order,
      fm.legacy_ref,
      (
        select jsonb_agg(coalesce(sp.player_ref, '') order by fms.slot_index)
        from bm.fix_match_slots fms
        left join bm.session_players sp
          on sp.id = fms.session_player_id
        where fms.fix_match_id = fm.id
      ) as slots_json
    from bm.fix_matches fm
    where fm.session_id = p_id
  ),
  game_rows as (
    select
      sg.session_id,
      sg.legacy_order,
      sg.slot_index,
      sg.court_index,
      gp.is_played,
      gp.played_order,
      gs.score_a,
      gs.score_b,
      (
        select jsonb_agg(sp.player_ref order by sgp.position)
        from bm.scheduled_game_players sgp
        join bm.session_players sp
          on sp.id = sgp.session_player_id
        where sgp.scheduled_game_id = sg.id
          and sgp.team = 'A'
      ) as team_a_json,
      (
        select jsonb_agg(sp.player_ref order by sgp.position)
        from bm.scheduled_game_players sgp
        join bm.session_players sp
          on sp.id = sgp.session_player_id
        where sgp.scheduled_game_id = sg.id
          and sgp.team = 'B'
      ) as team_b_json
    from bm.scheduled_games sg
    left join bm.game_progress gp
      on gp.scheduled_game_id = sg.id
    left join bm.game_scores gs
      on gs.scheduled_game_id = sg.id
    where sg.session_id = p_id
  )
  select
    case
      when exists (select 1 from target_session) then
        jsonb_build_object(
          'session', jsonb_build_object(
            'title', coalesce((select ts.title from target_session ts), ''),
            'date', (select ts.session_date::text from target_session ts),
            'courts', coalesce((select count(*)::integer from court_rows), 0),
            'sessionStart', coalesce((select to_char(ts.session_start, 'HH24:MI') from target_session ts), '00:00'),
            'slotMinutes', coalesce((select ts.slot_minutes from target_session ts), 20),
            'courtTimes', coalesce((
              select jsonb_agg(
                jsonb_build_object(
                  'start', to_char(cr.start_time, 'HH24:MI'),
                  'end', to_char(cr.end_time, 'HH24:MI')
                )
                order by cr.court_index
              )
              from court_rows cr
            ), '[]'::jsonb),
            'playerCount', coalesce((select count(*)::integer from player_rows), 0),
            'slotsPerCourt', coalesce((
              select jsonb_agg(cr.game_count order by cr.court_index)
              from court_rows cr
            ), '[]'::jsonb),
            'totalGames', coalesce((select count(*)::integer from game_rows), 0),
            'courtNames', case
              when exists (
                select 1
                from court_rows cr
                where cr.court_name <> ''
              ) then coalesce((
                select jsonb_agg(cr.court_name order by cr.court_index)
                from court_rows cr
              ), '[]'::jsonb)
              else '[]'::jsonb
            end,
            'locked', coalesce((select ts.status <> 'draft' from target_session ts), false)
          )
          ||
          case
            when coalesce((select ts.include_tier_count from target_session ts), false) then
              jsonb_build_object(
                'tierCount',
                coalesce((select ts.session_tier_count from target_session ts), 0)
              )
            else '{}'::jsonb
          end,
          'players', coalesce((
            select jsonb_agg(
              jsonb_build_object(
                'name', pr.source_name,
                'gender', pr.gender,
                'tier', pr.tier,
                'id', pr.player_ref
              )
              order by pr.sort_order
            )
            from player_rows pr
          ), '[]'::jsonb),
          'fixMatches', coalesce((
            select jsonb_agg(
              jsonb_build_object(
                'slots', coalesce(fmr.slots_json, '[]'::jsonb),
                'id', fmr.legacy_ref
              )
              order by fmr.sort_order
            )
            from fix_match_rows fmr
          ), '[]'::jsonb),
          'schedule', coalesce((
            select jsonb_agg(
              jsonb_build_object(
                'slot', gr.slot_index,
                'court', gr.court_index,
                'teamA', coalesce(gr.team_a_json, '[]'::jsonb),
                'teamB', coalesce(gr.team_b_json, '[]'::jsonb)
              )
              order by gr.legacy_order
            )
            from game_rows gr
          ), '[]'::jsonb),
          'playedGames', coalesce((
            select jsonb_agg(
              to_jsonb(concat(gr.slot_index, '-', gr.court_index))
              order by gr.played_order
            )
            from game_rows gr
            where coalesce(gr.is_played, false)
              and gr.played_order is not null
          ), '[]'::jsonb),
          'gameScores', coalesce((
            select jsonb_object_agg(
              concat(gr.slot_index, '-', gr.court_index),
              jsonb_build_object('a', gr.score_a, 'b', gr.score_b)
            )
            from game_rows gr
            where gr.score_a is not null
              and gr.score_b is not null
          ), '{}'::jsonb),
          )
          ||
          case
            when coalesce((select ts.include_absent_players from target_session ts), false) then
              jsonb_build_object(
                'absentPlayers',
                coalesce((
                  select jsonb_agg(to_jsonb(pr.player_ref) order by pr.absent_order, pr.sort_order)
                  from player_rows pr
                  where pr.is_absent
                ), '[]'::jsonb)
              )
            else '{}'::jsonb
          end
      else null
    end;
$$;

create or replace function bm.get_session(p_id text)
returns jsonb
language sql
security definer
set search_path = bm, public
as $$
  select bm.get_session_snapshot_compat(p_id);
$$;

create or replace function bm.list_sessions()
returns table (
  id text,
  title text,
  date text,
  player_count integer,
  total_games integer
)
language sql
security definer
set search_path = bm, public
as $$
  select
    s.id,
    s.title,
    s.session_date::text as date,
    coalesce(player_counts.player_count, 0) as player_count,
    coalesce(game_counts.total_games, 0) as total_games
  from bm.sessions s
  left join (
    select
      sp.session_id,
      count(*)::integer as player_count
    from bm.session_players sp
    group by sp.session_id
  ) player_counts
    on player_counts.session_id = s.id
  left join (
    select
      sg.session_id,
      count(*)::integer as total_games
    from bm.scheduled_games sg
    group by sg.session_id
  ) game_counts
    on game_counts.session_id = s.id
  order by s.session_date desc, s.updated_at desc;
$$;

create or replace function bm.list_players()
returns table (
  name text,
  gender text,
  tier integer
)
language sql
security definer
set search_path = bm, public
as $$
  with ranked_appearances as (
    select
      p.id as player_id,
      p.canonical_name,
      sp.gender,
      sp.tier,
      row_number() over (
        partition by p.id
        order by s.session_date desc, sp.updated_at desc, sp.id desc
      ) as rn
    from bm.players p
    join bm.session_players sp
      on sp.player_id = p.id
    join bm.sessions s
      on s.id = sp.session_id
  )
  select
    ra.canonical_name as name,
    ra.gender,
    ra.tier
  from ranked_appearances ra
  where ra.rn = 1
  order by lower(ra.canonical_name);
$$;

create or replace function bm.get_player_stats_compat(p_name text)
returns jsonb
language plpgsql
security definer
set search_path = bm, public
as $$
declare
  v_player_id uuid;
  v_resolved_name text := p_name;
  v_games_played integer := 0;
  v_wins integer := 0;
  v_losses integer := 0;
  v_points_for integer := 0;
  v_points_against integer := 0;
  v_sessions jsonb := '[]'::jsonb;
  v_top_partners jsonb := '[]'::jsonb;
  v_top_opponents jsonb := '[]'::jsonb;
begin
  select
    p.id,
    p.canonical_name
  into
    v_player_id,
    v_resolved_name
  from bm.player_aliases pa
  join bm.players p
    on p.id = pa.player_id
  where pa.alias_name = bm.normalize_player_name(p_name)
  limit 1;

  if v_player_id is null then
    return jsonb_build_object(
      'name', p_name,
      'gamesPlayed', 0,
      'wins', 0,
      'losses', 0,
      'pointsFor', 0,
      'pointsAgainst', 0,
      'sessions', '[]'::jsonb,
      'topPartners', '[]'::jsonb,
      'topOpponents', '[]'::jsonb
    );
  end if;

  with target_memberships as (
    select
      sp.id as session_player_id,
      sp.session_id,
      sp.is_absent
    from bm.session_players sp
    where sp.player_id = v_player_id
  ),
  session_rows as (
    select
      tm.session_id as id,
      s.session_date::text as date,
      s.title,
      tm.is_absent as absent
    from target_memberships tm
    join bm.sessions s
      on s.id = tm.session_id
  ),
  player_games as (
    select
      tm.session_id,
      tm.session_player_id,
      sg.id as scheduled_game_id,
      sgp.team as player_team,
      gs.score_a,
      gs.score_b
    from target_memberships tm
    join bm.scheduled_game_players sgp
      on sgp.session_player_id = tm.session_player_id
    join bm.scheduled_games sg
      on sg.id = sgp.scheduled_game_id
    left join bm.game_scores gs
      on gs.scheduled_game_id = sg.id
  ),
  base_stats as (
    select
      count(*)::integer as games_played,
      coalesce(sum(case
        when pg.score_a is null or pg.score_b is null then 0
        when pg.player_team = 'A' and pg.score_a > pg.score_b then 1
        when pg.player_team = 'B' and pg.score_b > pg.score_a then 1
        else 0
      end), 0)::integer as wins,
      coalesce(sum(case
        when pg.score_a is null or pg.score_b is null then 0
        when pg.player_team = 'A' and pg.score_a < pg.score_b then 1
        when pg.player_team = 'B' and pg.score_b < pg.score_a then 1
        else 0
      end), 0)::integer as losses,
      coalesce(sum(case
        when pg.score_a is null or pg.score_b is null then 0
        when pg.player_team = 'A' then pg.score_a
        else pg.score_b
      end), 0)::integer as points_for,
      coalesce(sum(case
        when pg.score_a is null or pg.score_b is null then 0
        when pg.player_team = 'A' then pg.score_b
        else pg.score_a
      end), 0)::integer as points_against
    from player_games pg
  ),
  partner_rows as (
    select
      partner.canonical_name as partner_name,
      count(*)::integer as count,
      coalesce(sum(case
        when pg.score_a is null or pg.score_b is null then 0
        when pg.player_team = 'A' and pg.score_a > pg.score_b then 1
        when pg.player_team = 'B' and pg.score_b > pg.score_a then 1
        else 0
      end), 0)::integer as wins,
      coalesce(sum(case
        when pg.score_a is null or pg.score_b is null then 0
        when pg.player_team = 'A' and pg.score_a < pg.score_b then 1
        when pg.player_team = 'B' and pg.score_b < pg.score_a then 1
        else 0
      end), 0)::integer as losses
    from player_games pg
    join bm.scheduled_game_players teammate_link
      on teammate_link.scheduled_game_id = pg.scheduled_game_id
     and teammate_link.team = pg.player_team
     and teammate_link.session_player_id <> pg.session_player_id
    join bm.session_players teammate_sp
      on teammate_sp.id = teammate_link.session_player_id
    join bm.players partner
      on partner.id = teammate_sp.player_id
    group by partner.canonical_name
    order by count desc, lower(partner.canonical_name)
    limit 5
  ),
  opponent_rows as (
    select
      opponent.canonical_name as opponent_name,
      count(*)::integer as count,
      coalesce(sum(case
        when pg.score_a is null or pg.score_b is null then 0
        when pg.player_team = 'A' and pg.score_a > pg.score_b then 1
        when pg.player_team = 'B' and pg.score_b > pg.score_a then 1
        else 0
      end), 0)::integer as wins,
      coalesce(sum(case
        when pg.score_a is null or pg.score_b is null then 0
        when pg.player_team = 'A' and pg.score_a < pg.score_b then 1
        when pg.player_team = 'B' and pg.score_b < pg.score_a then 1
        else 0
      end), 0)::integer as losses
    from player_games pg
    join bm.scheduled_game_players opponent_link
      on opponent_link.scheduled_game_id = pg.scheduled_game_id
     and opponent_link.team <> pg.player_team
    join bm.session_players opponent_sp
      on opponent_sp.id = opponent_link.session_player_id
    join bm.players opponent
      on opponent.id = opponent_sp.player_id
    group by opponent.canonical_name
    order by count desc, lower(opponent.canonical_name)
    limit 5
  )
  select
    coalesce((select bs.games_played from base_stats bs), 0),
    coalesce((select bs.wins from base_stats bs), 0),
    coalesce((select bs.losses from base_stats bs), 0),
    coalesce((select bs.points_for from base_stats bs), 0),
    coalesce((select bs.points_against from base_stats bs), 0),
    coalesce((select jsonb_agg(to_jsonb(sr) order by sr.date desc) from session_rows sr), '[]'::jsonb),
    coalesce((select jsonb_agg(jsonb_build_object(
      'name', pr.partner_name,
      'count', pr.count,
      'wins', pr.wins,
      'losses', pr.losses
    )) from partner_rows pr), '[]'::jsonb),
    coalesce((select jsonb_agg(jsonb_build_object(
      'name', orow.opponent_name,
      'count', orow.count,
      'wins', orow.wins,
      'losses', orow.losses
    )) from opponent_rows orow), '[]'::jsonb)
  into
    v_games_played,
    v_wins,
    v_losses,
    v_points_for,
    v_points_against,
    v_sessions,
    v_top_partners,
    v_top_opponents;

  return jsonb_build_object(
    'name', v_resolved_name,
    'gamesPlayed', v_games_played,
    'wins', v_wins,
    'losses', v_losses,
    'pointsFor', v_points_for,
    'pointsAgainst', v_points_against,
    'sessions', v_sessions,
    'topPartners', v_top_partners,
    'topOpponents', v_top_opponents
  );
end;
$$;

create or replace function bm.get_player_stats(p_name text)
returns jsonb
language sql
security definer
set search_path = bm, public
as $$
  select bm.get_player_stats_compat(p_name);
$$;

create or replace function bm.report_legacy_unresolved_names()
returns table (
  normalized_name text,
  raw_names jsonb,
  session_ids jsonb,
  occurrences bigint
)
language sql
security definer
set search_path = bm, badminton_match, public
as $$
  with snapshot_players as (
    select
      s.id as session_id,
      player->>'name' as raw_name,
      bm.normalize_player_name(player->>'name') as normalized_name
    from badminton_match.sessions s
    cross join lateral jsonb_array_elements(coalesce(s.snapshot->'players', '[]'::jsonb)) as player
  ),
  unresolved as (
    select sp.*
    from snapshot_players sp
    left join bm.player_aliases pa
      on pa.alias_name = sp.normalized_name
    where sp.normalized_name is null
       or pa.player_id is null
  )
  select
    u.normalized_name,
    jsonb_agg(distinct to_jsonb(u.raw_name)) as raw_names,
    jsonb_agg(distinct to_jsonb(u.session_id)) as session_ids,
    count(*) as occurrences
  from unresolved u
  group by u.normalized_name
  order by count(*) desc, u.normalized_name;
$$;

create or replace function bm.backfill_legacy_session(p_id text)
returns void
language plpgsql
security definer
set search_path = bm, badminton_match, public
as $$
declare
  v_snapshot jsonb;
begin
  select s.snapshot
  into v_snapshot
  from badminton_match.sessions s
  where s.id = p_id;

  if v_snapshot is null then
    raise exception 'legacy badminton_match session not found: %', p_id;
  end if;

  perform bm.publish_session(p_id, v_snapshot, 'legacy_snapshot');
end;
$$;

create or replace function bm.backfill_legacy_sessions()
returns table (session_id text)
language plpgsql
security definer
set search_path = bm, badminton_match, public
as $$
declare
  rec record;
begin
  for rec in
    select s.id
    from badminton_match.sessions s
    order by s.session_date asc, s.updated_at asc, s.id asc
  loop
    perform bm.backfill_legacy_session(rec.id);
    session_id := rec.id;
    return next;
  end loop;
end;
$$;

grant usage on schema bm to anon, authenticated, service_role;
grant select, insert, update, delete on all tables in schema bm to postgres, service_role;
grant usage, select on all sequences in schema bm to postgres, service_role;

grant execute on function bm.publish_session(text, jsonb, text) to anon, authenticated, service_role;
grant execute on function bm.get_session_snapshot_compat(text) to anon, authenticated, service_role;
grant execute on function bm.get_session(text) to anon, authenticated, service_role;
grant execute on function bm.list_sessions() to anon, authenticated, service_role;
grant execute on function bm.list_players() to anon, authenticated, service_role;
grant execute on function bm.get_player_stats_compat(text) to anon, authenticated, service_role;
grant execute on function bm.get_player_stats(text) to anon, authenticated, service_role;
grant execute on function bm.ensure_player(text) to service_role;
grant execute on function bm.register_player_alias(text, text) to service_role;
grant execute on function bm.resolve_player_id(text) to service_role;
grant execute on function bm.report_legacy_unresolved_names() to authenticated, service_role;
grant execute on function bm.backfill_legacy_session(text) to service_role;
grant execute on function bm.backfill_legacy_sessions() to service_role;
