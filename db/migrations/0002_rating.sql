-- 0002: rating events, deltas, snapshots and achievements.
-- Idempotency of rating inputs is enforced by the schema, not by application
-- bookkeeping: one delta per (event, side, player).

create schema if not exists rating;
create schema if not exists achievement;

create table rating.events (
  id uuid primary key default gen_random_uuid(),
  community_id uuid not null references platform.community(id) on delete restrict,
  local_date date not null,
  event_type text not null,
  source_id uuid,
  created_at timestamptz not null default now(),
  constraint events_community_id_unique unique (community_id, id),
  constraint events_type_check check (event_type in ('session', 'tournament', 'manual'))
);

create index events_community_date_idx
  on rating.events (community_id, local_date desc);

create table rating.deltas (
  id uuid primary key default gen_random_uuid(),
  community_id uuid not null,
  event_id uuid not null,
  side text not null,
  player_id uuid not null,
  delta integer not null,
  created_at timestamptz not null default now(),
  constraint deltas_event_fk foreign key (community_id, event_id)
    references rating.events (community_id, id) on delete restrict,
  constraint deltas_player_fk foreign key (community_id, player_id)
    references player.players (community_id, id) on delete restrict,
  constraint deltas_side_check check (side in ('a', 'b')),
  constraint deltas_unique_per_side unique (event_id, side, player_id)
);

create index deltas_community_event_idx on rating.deltas (community_id, event_id);
create index deltas_community_player_idx on rating.deltas (community_id, player_id);
create index deltas_player_idx on rating.deltas (event_id, side, player_id);

create table rating.player_state (
  community_id uuid not null references platform.community(id) on delete restrict,
  player_id uuid not null,
  rating integer not null,
  games_played integer not null default 0,
  wins integer not null default 0,
  losses integer not null default 0,
  updated_at timestamptz not null default now(),
  primary key (community_id, player_id),
  constraint player_state_player_fk foreign key (community_id, player_id)
    references player.players (community_id, id) on delete cascade,
  constraint player_state_games_check check (games_played = wins + losses)
);

create table rating.snapshots (
  community_id uuid not null references platform.community(id) on delete restrict,
  player_id uuid not null,
  taken_on date not null,
  rating integer not null,
  primary key (community_id, player_id, taken_on),
  constraint snapshots_player_fk foreign key (community_id, player_id)
    references player.players (community_id, id) on delete cascade
);

create index snapshots_community_date_idx
  on rating.snapshots (community_id, taken_on desc);

create table achievement.definitions (
  key text primary key,
  category text not null,
  threshold integer not null,
  constraint achievement_threshold_non_negative check (threshold >= 0)
);

create table achievement.earned (
  community_id uuid not null,
  player_id uuid not null,
  achievement_key text not null references achievement.definitions(key) on delete restrict,
  earned_at timestamptz not null default now(),
  primary key (community_id, player_id, achievement_key),
  constraint earned_player_fk foreign key (community_id, player_id)
    references player.players (community_id, id) on delete cascade
);

create index earned_key_idx on achievement.earned (achievement_key);

grant usage on schema rating, achievement to bm2_app;
grant select, insert, update, delete on all tables in schema rating to bm2_app;
grant select, insert, update, delete on all tables in schema achievement to bm2_app;
