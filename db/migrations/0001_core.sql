-- 0001: platform identity, sessions, links, games and players.
-- Tenancy starts here: platform.community and platform.user exist before any
-- table that references them (D1).

create schema if not exists platform;
create schema if not exists session;
create schema if not exists player;

create table platform.community (
  id uuid primary key default gen_random_uuid(),
  slug text not null,
  name text not null,
  timezone text not null,
  created_at timestamptz not null default now(),
  constraint community_slug_global_unique unique (slug),
  constraint community_slug_format check (slug ~ '^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$'),
  constraint community_name_not_blank check (btrim(name) <> ''),
  constraint community_timezone_not_blank check (btrim(timezone) <> '')
);

create table platform.user (
  id uuid primary key default gen_random_uuid(),
  google_sub text not null,
  email_hash text not null,
  display_name text not null default '',
  created_at timestamptz not null default now(),
  constraint user_google_sub_unique unique (google_sub),
  constraint user_email_hash_unique unique (email_hash)
);

create table session.sessions (
  id uuid primary key default gen_random_uuid(),
  community_id uuid not null references platform.community(id) on delete restrict,
  title text not null default '',
  session_date date not null,
  start_time time not null default '00:00',
  slot_minutes integer not null default 30,
  status text not null,
  source text not null,
  version integer not null default 1,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint sessions_community_id_unique unique (community_id, id),
  constraint sessions_status_check check (status in ('draft', 'locked', 'published', 'completed', 'archived')),
  constraint sessions_source_check check (source in ('manual', 'generator', 'legacy_snapshot')),
  constraint sessions_version_positive check (version > 0),
  constraint sessions_slot_minutes_positive check (slot_minutes > 0)
);

create index sessions_community_date_idx
  on session.sessions (community_id, session_date desc, updated_at desc);

create table session.links (
  -- No DEFAULT: the application must know the id before it builds the AAD.
  id uuid primary key,
  community_id uuid not null,
  session_id uuid not null,
  code_hash bytea not null,
  code_enc bytea not null,
  key_id text not null,
  created_by uuid references platform.user(id) on delete set null,
  created_at timestamptz not null default now(),
  revoked_at timestamptz,
  expires_at timestamptz,
  constraint links_code_hash_unique unique (code_hash),
  constraint links_session_fk foreign key (community_id, session_id)
    references session.sessions (community_id, id) on delete cascade
);

create unique index links_one_live
  on session.links (session_id) where revoked_at is null;

create index links_community_session_idx
  on session.links (community_id, session_id);

create table session.courts (
  id uuid primary key default gen_random_uuid(),
  community_id uuid not null,
  session_id uuid not null,
  court_index integer not null,
  court_name text not null default '',
  start_time time not null,
  end_time time not null,
  constraint courts_session_fk foreign key (community_id, session_id)
    references session.sessions (community_id, id) on delete cascade,
  constraint courts_session_index_unique unique (session_id, court_index),
  constraint courts_time_range check (end_time > start_time),
  constraint courts_index_non_negative check (court_index >= 0)
);

create index courts_community_session_idx
  on session.courts (community_id, session_id);

create table session.games (
  id uuid primary key default gen_random_uuid(),
  community_id uuid not null,
  session_id uuid not null,
  round_no integer not null,
  court_no integer not null,
  score_a integer,
  score_b integer,
  status text not null default 'scheduled',
  version integer not null default 1,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint games_session_fk foreign key (community_id, session_id)
    references session.sessions (community_id, id) on delete cascade,
  constraint games_round_court_unique unique (session_id, round_no, court_no),
  constraint games_status_check check (status in ('scheduled', 'played', 'cancelled')),
  constraint games_score_range check (
    (score_a is null or score_a between 0 and 99) and
    (score_b is null or score_b between 0 and 99)),
  constraint games_not_tied check (
    not (status = 'played' and score_a is not null and score_b is not null
         and score_a = score_b)),
  constraint games_indexes_non_negative check (round_no >= 0 and court_no >= 0)
);

create index games_community_session_idx
  on session.games (community_id, session_id);

create or replace function session.bump_version() returns trigger
language plpgsql as $$
begin
  new.version := old.version + 1;
  new.updated_at := now();
  return new;
end;
$$;

create trigger games_bump_version
  before update on session.games
  for each row execute function session.bump_version();

create table player.players (
  id uuid primary key default gen_random_uuid(),
  community_id uuid not null references platform.community(id) on delete restrict,
  canonical_name text not null,
  canonical_key text generated always as (
    btrim(regexp_replace(lower(canonical_name), '\s+', ' ', 'g'))
  ) stored,
  tier text,
  gender text not null default 'M',
  user_id uuid references platform.user(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint players_community_id_unique unique (community_id, id),
  constraint players_community_key_unique unique (community_id, canonical_key),
  constraint players_name_not_blank check (btrim(canonical_name) <> ''),
  constraint players_gender_check check (gender in ('M', 'F')),
  constraint players_tier_check check (
    tier is null or tier in ('D', 'D+', 'C', 'C+', 'B', 'B+', 'A', 'A+'))
);

create unique index players_one_owner_per_user
  on player.players (community_id, user_id) where user_id is not null;

create index players_community_user_idx
  on player.players (community_id, user_id) where user_id is not null;

create table player.claims (
  id uuid primary key default gen_random_uuid(),
  community_id uuid not null,
  player_id uuid not null,
  user_id uuid not null references platform.user(id) on delete cascade,
  status text not null default 'pending',
  decided_by uuid references platform.user(id) on delete set null,
  decided_at timestamptz,
  reason text,
  created_at timestamptz not null default now(),
  constraint claims_player_fk foreign key (community_id, player_id)
    references player.players (community_id, id) on delete cascade,
  constraint claims_status_check check (status in ('pending', 'approved', 'rejected', 'released')),
  constraint claims_decision_fields check (
    (status = 'pending') = (decided_at is null) and
    (status = 'pending') = (decided_by is null) and
    (status = 'pending') = (reason is null))
);

create unique index claims_one_pending
  on player.claims (community_id, player_id) where status = 'pending';

create unique index claims_one_approved
  on player.claims (player_id) where status = 'approved';

create index claims_community_player_idx
  on player.claims (community_id, player_id);

create table player.merge_log (
  id uuid primary key default gen_random_uuid(),
  community_id uuid not null,
  source_id uuid not null,
  target_id uuid not null,
  rows_moved integer not null,
  actor_id uuid not null,
  created_at timestamptz not null default now(),
  constraint merge_log_rows_non_negative check (rows_moved >= 0)
);

create index merge_log_community_idx on player.merge_log (community_id, created_at desc);

-- Application grants. The owner runs migrations; the app never gets DDL.
grant usage on schema platform, session, player to bm2_app;
grant select, insert, update, delete on all tables in schema platform to bm2_app;
grant select, insert, update, delete on all tables in schema session to bm2_app;
grant select, insert, update, delete on all tables in schema player to bm2_app;

-- Merge history is evidence: the application can append, never rewrite.
revoke update, delete on player.merge_log from bm2_app;
grant select, insert on player.merge_log to bm2_app;
