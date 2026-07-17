-- =========================================================================
-- Consolidated schema: all DDL in final state (squashed from migrations 000001–000053)
-- =========================================================================

-- ── Schemas ──────────────────────────────────────────────────────────────

create schema if not exists bm;

-- Legacy schema retained temporarily for seed backfill compatibility.
-- Dropped at the end of this file after seeds have been applied via
-- supabase/migrations/20260616_000003_seeds.sql.
-- If you are running this on a clean database without seeds, the DROP at
-- the bottom is harmless.

create schema if not exists badminton_match;

-- ── Helper functions (required by table constraints) ─────────────────────

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

-- ── Tables ───────────────────────────────────────────────────────────────

-- bm.players
create table if not exists bm.players (
  id uuid primary key default gen_random_uuid(),
  canonical_name text not null unique,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint bm_players_canonical_name_not_blank_ck check (trim(canonical_name) <> '')
);

-- bm.player_aliases
create table if not exists bm.player_aliases (
  alias_name text primary key,
  player_id uuid not null references bm.players(id) on delete cascade,
  created_at timestamptz not null default now(),
  constraint player_aliases_alias_name_normalized_ck
    check (alias_name = bm.normalize_player_name(alias_name))
);

-- bm.sessions
create table if not exists bm.sessions (
  id text primary key,
  internal_id uuid not null default gen_random_uuid(),
  share_id text not null,
  title text not null default '',
  session_date date not null,
  session_start time not null default '00:00'::time,
  slot_minutes integer not null check (slot_minutes > 0),
  session_tier_count integer not null default 0 check (session_tier_count >= 0),
  include_tier_count boolean not null default false,
  include_absent_players boolean not null default false,
  status text not null check (status in ('draft', 'locked', 'published', 'completed', 'archived')),
  source text not null check (source in ('compat_publish', 'legacy_snapshot', 'manual')),
  version integer not null default 1,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint bm_sessions_internal_id_key unique (internal_id),
  constraint bm_sessions_share_id_key unique (share_id),
  constraint bm_sessions_share_id_not_blank_ck check (trim(share_id) <> ''),
  constraint bm_sessions_id_not_blank_ck check (trim(id) <> ''),
  constraint bm_sessions_id_internal_id_key unique (id, internal_id),
  constraint bm_sessions_version_positive_ck check (version > 0)
);

-- bm.session_courts
create table if not exists bm.session_courts (
  internal_id uuid primary key default gen_random_uuid(),
  session_id text not null,
  session_internal_id uuid not null,
  court_index integer not null check (court_index >= 0),
  court_name text not null default '',
  start_time time not null,
  end_time time not null,
  constraint bm_session_courts_session_identity_fk
    foreign key (session_id, session_internal_id)
    references bm.sessions (id, internal_id)
    on delete cascade,
  constraint bm_session_courts_session_internal_court_key
    unique (session_internal_id, court_index),
  constraint bm_session_courts_time_range_ck check (end_time > start_time)
);

-- bm.session_players
create table if not exists bm.session_players (
  internal_id uuid primary key default gen_random_uuid(),
  session_id text not null,
  session_internal_id uuid not null,
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
  constraint bm_session_players_session_identity_fk
    foreign key (session_id, session_internal_id)
    references bm.sessions (id, internal_id)
    on delete cascade,
  constraint bm_session_players_session_internal_player_key
    unique (session_internal_id, player_id),
  constraint bm_session_players_session_internal_player_ref_key
    unique (session_internal_id, player_ref),
  constraint bm_session_players_session_internal_sort_order_key
    unique (session_internal_id, sort_order),
  constraint bm_session_players_player_ref_not_blank_ck check (trim(player_ref) <> ''),
  constraint bm_session_players_source_name_not_blank_ck check (trim(source_name) <> '')
);

-- bm.fix_matches
create table if not exists bm.fix_matches (
  internal_id uuid primary key default gen_random_uuid(),
  session_id text not null,
  session_internal_id uuid not null,
  legacy_ref text not null,
  sort_order integer not null default 0 check (sort_order >= 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint bm_fix_matches_session_identity_fk
    foreign key (session_id, session_internal_id)
    references bm.sessions (id, internal_id)
    on delete cascade,
  constraint bm_fix_matches_session_internal_legacy_ref_key
    unique (session_internal_id, legacy_ref),
  constraint bm_fix_matches_session_internal_sort_order_key
    unique (session_internal_id, sort_order),
  constraint bm_fix_matches_legacy_ref_not_blank_ck check (trim(legacy_ref) <> '')
);

-- bm.fix_match_slots
create table if not exists bm.fix_match_slots (
  internal_id uuid primary key default gen_random_uuid(),
  fix_match_internal_id uuid not null,
  slot_index integer not null check (slot_index between 0 and 3),
  session_player_internal_id uuid null,
  constraint bm_fix_match_slots_fix_match_internal_fk
    foreign key (fix_match_internal_id)
    references bm.fix_matches (internal_id)
    on delete cascade,
  constraint bm_fix_match_slots_session_player_internal_fk
    foreign key (session_player_internal_id)
    references bm.session_players (internal_id)
    on delete set null,
  constraint bm_fix_match_slots_fix_match_internal_slot_key
    unique (fix_match_internal_id, slot_index)
);

-- bm.scheduled_games
create table if not exists bm.scheduled_games (
  internal_id uuid primary key default gen_random_uuid(),
  session_id text not null,
  session_internal_id uuid not null,
  legacy_order integer not null check (legacy_order >= 0),
  slot_index integer not null check (slot_index >= 0),
  court_index integer not null check (court_index >= 0),
  status text not null check (status in ('scheduled', 'played', 'cancelled')),
  source text not null check (source in ('generator', 'manual', 'constraint', 'legacy_snapshot', 'compat_publish')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint bm_scheduled_games_session_identity_fk
    foreign key (session_id, session_internal_id)
    references bm.sessions (id, internal_id)
    on delete cascade,
  constraint bm_scheduled_games_session_internal_slot_court_key
    unique (session_internal_id, slot_index, court_index),
  constraint bm_scheduled_games_session_internal_legacy_order_key
    unique (session_internal_id, legacy_order)
);

-- bm.scheduled_game_players
create table if not exists bm.scheduled_game_players (
  internal_id uuid primary key default gen_random_uuid(),
  scheduled_game_internal_id uuid not null,
  session_player_internal_id uuid not null,
  team text not null check (team in ('A', 'B')),
  position integer not null check (position in (0, 1)),
  constraint bm_scheduled_game_players_game_internal_fk
    foreign key (scheduled_game_internal_id)
    references bm.scheduled_games (internal_id)
    on delete cascade,
  constraint bm_scheduled_game_players_session_player_internal_fk
    foreign key (session_player_internal_id)
    references bm.session_players (internal_id)
    on delete cascade,
  constraint bm_scheduled_game_players_game_internal_team_pos_key
    unique (scheduled_game_internal_id, team, position),
  constraint bm_scheduled_game_players_game_internal_player_key
    unique (scheduled_game_internal_id, session_player_internal_id)
);

-- bm.game_progress
create table if not exists bm.game_progress (
  scheduled_game_internal_id uuid primary key,
  is_played boolean not null default false,
  played_order integer null check (played_order >= 0),
  updated_at timestamptz not null default now(),
  constraint bm_game_progress_scheduled_game_internal_fk
    foreign key (scheduled_game_internal_id)
    references bm.scheduled_games (internal_id)
    on delete cascade
);

-- bm.game_scores
create table if not exists bm.game_scores (
  scheduled_game_internal_id uuid primary key,
  score_a integer not null check (score_a between 0 and 99),
  score_b integer not null check (score_b between 0 and 99),
  entered_at timestamptz not null default now(),
  constraint bm_game_scores_scheduled_game_internal_fk
    foreign key (scheduled_game_internal_id)
    references bm.scheduled_games (internal_id)
    on delete cascade,
  constraint bm_game_scores_not_tied_ck check (score_a <> score_b)
);

-- bm.tournaments
create table if not exists bm.tournaments (
  id text primary key,
  internal_id uuid not null default gen_random_uuid(),
  share_id text not null,
  name text not null default '',
  event_date date not null default current_date,
  snapshot jsonb not null default '{}'::jsonb,
  version integer not null default 1,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint bm_tournaments_internal_id_key unique (internal_id),
  constraint bm_tournaments_share_id_key unique (share_id),
  constraint bm_tournaments_id_not_blank_ck check (trim(id) <> ''),
  constraint bm_tournaments_share_id_not_blank_ck check (trim(share_id) <> ''),
  constraint bm_tournaments_version_positive_ck check (version > 0),
  constraint bm_tournaments_snapshot_object_ck check (jsonb_typeof(snapshot) = 'object')
);

-- ── Indexes ──────────────────────────────────────────────────────────────

create index if not exists bm_player_aliases_player_id_idx
  on bm.player_aliases (player_id);

create index if not exists bm_sessions_session_date_idx
  on bm.sessions (session_date desc);

create index if not exists bm_sessions_updated_at_idx
  on bm.sessions (updated_at desc);

create index if not exists bm_sessions_share_id_idx
  on bm.sessions (share_id);

create index if not exists bm_session_courts_session_id_idx
  on bm.session_courts (session_id);

create index if not exists bm_session_courts_session_internal_id_idx
  on bm.session_courts (session_internal_id);

create index if not exists bm_session_courts_session_internal_court_idx
  on bm.session_courts (session_internal_id, court_index);

create index if not exists bm_session_players_player_id_idx
  on bm.session_players (player_id);

create index if not exists bm_session_players_session_internal_id_idx
  on bm.session_players (session_internal_id);

create index if not exists bm_session_players_session_internal_player_ref_idx
  on bm.session_players (session_internal_id, player_ref);

create index if not exists bm_session_players_session_absent_order_idx
  on bm.session_players (session_id, is_absent, absent_order, sort_order);

create index if not exists bm_session_players_player_session_recent_idx
  on bm.session_players (player_id, session_internal_id, updated_at desc, internal_id desc);

create index if not exists bm_fix_matches_session_id_idx
  on bm.fix_matches (session_id);

create index if not exists bm_fix_matches_session_internal_id_idx
  on bm.fix_matches (session_internal_id);

create index if not exists bm_fix_matches_session_internal_legacy_ref_idx
  on bm.fix_matches (session_internal_id, legacy_ref);

create index if not exists bm_fix_match_slots_fix_match_internal_id_idx
  on bm.fix_match_slots (fix_match_internal_id);

create index if not exists bm_fix_match_slots_session_player_internal_id_idx
  on bm.fix_match_slots (session_player_internal_id);

create index if not exists bm_scheduled_games_session_id_idx
  on bm.scheduled_games (session_id);

create index if not exists bm_scheduled_games_session_internal_id_idx
  on bm.scheduled_games (session_internal_id);

create index if not exists bm_scheduled_games_session_internal_slot_court_idx
  on bm.scheduled_games (session_internal_id, slot_index, court_index);

create index if not exists bm_scheduled_game_players_game_internal_id_idx
  on bm.scheduled_game_players (scheduled_game_internal_id);

create index if not exists bm_scheduled_game_players_session_player_internal_id_idx
  on bm.scheduled_game_players (session_player_internal_id);

create index if not exists bm_scheduled_game_players_session_player_game_idx
  on bm.scheduled_game_players (session_player_internal_id, scheduled_game_internal_id);

create index if not exists bm_game_progress_played_order_idx
  on bm.game_progress (played_order)
  where is_played;

create index if not exists bm_tournaments_event_date_idx
  on bm.tournaments (event_date desc);

create index if not exists bm_tournaments_updated_at_idx
  on bm.tournaments (updated_at desc);

create index if not exists bm_tournaments_share_id_idx
  on bm.tournaments (share_id);

-- ── Triggers ─────────────────────────────────────────────────────────────

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

drop trigger if exists bm_tournaments_set_updated_at on bm.tournaments;
create trigger bm_tournaments_set_updated_at
before update on bm.tournaments
for each row
execute function bm.set_updated_at();

drop trigger if exists bm_game_progress_set_updated_at on bm.game_progress;
create trigger bm_game_progress_set_updated_at
before update on bm.game_progress
for each row
execute function bm.set_updated_at();

-- ── Grants ───────────────────────────────────────────────────────────────

grant usage on schema bm to anon, authenticated, service_role;
grant select, insert, update, delete on all tables in schema bm to postgres, service_role;
grant usage, select on all sequences in schema bm to postgres, service_role;

grant usage on schema badminton_match to postgres, anon, authenticated, service_role;
grant select, insert, update, delete on all tables in schema badminton_match to postgres, service_role;

-- ── Legacy schema (for seed backfill) ────────────────────────────────────
-- These tables mirror the original 000001 schema and exist only so that
-- legacy_snapshot_backfill.sql can insert raw JSON snapshots.
-- They are dropped at the bottom of this file after seeds run, OR can be
-- dropped manually after seeding is complete.

create table if not exists badminton_match.sessions (
  id text primary key,
  title text not null default '',
  session_date date not null,
  player_count integer not null,
  total_games integer not null,
  published_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  snapshot jsonb not null
);

create table if not exists badminton_match.tournaments (
  id text primary key,
  name text not null,
  event_date date not null,
  updated_at timestamptz not null default now(),
  snapshot jsonb not null
);

-- ── Drop legacy schema ───────────────────────────────────────────────────
-- This runs AFTER seeds have been applied.  The seed file
-- (20260616_000003_seeds.sql) inserts into badminton_match.* first, then
-- backfills into bm.*.  Because Supabase runs migrations in filename order,
-- and 000001 < 000003, this DROP executes before seeds.  We therefore
-- comment it out and include it as the LAST statement in the seeds file
-- instead.
--
-- drop schema if exists badminton_match cascade;
