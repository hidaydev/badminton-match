-- 0003: tournaments, pairs and matches.
-- Tournament history is relational, not a JSON blob; deletion order is guarded
-- by RESTRICT on rating deltas and by explicit task-level cleanup.

create schema if not exists tournament;

create table tournament.tournaments (
  id uuid primary key default gen_random_uuid(),
  community_id uuid not null references platform.community(id) on delete restrict,
  name text not null,
  status text not null default 'draft',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint tournaments_community_id_unique unique (community_id, id),
  constraint tournaments_status_check check (status in ('draft', 'active', 'completed', 'archived')),
  constraint tournaments_name_not_blank check (btrim(name) <> '')
);

create index tournaments_community_idx
  on tournament.tournaments (community_id, created_at desc);

create table tournament.pairs (
  id uuid primary key default gen_random_uuid(),
  community_id uuid not null,
  tournament_id uuid not null,
  display_name text not null,
  player_a_id uuid not null,
  player_b_id uuid not null,
  created_at timestamptz not null default now(),
  constraint pairs_tournament_fk foreign key (community_id, tournament_id)
    references tournament.tournaments (community_id, id) on delete cascade,
  constraint pairs_player_a_fk foreign key (community_id, player_a_id)
    references player.players (community_id, id) on delete restrict,
  constraint pairs_player_b_fk foreign key (community_id, player_b_id)
    references player.players (community_id, id) on delete restrict,
  constraint pairs_community_id_unique unique (community_id, id),
  constraint pairs_distinct_players check (player_a_id <> player_b_id)
);

create index pairs_community_tournament_idx
  on tournament.pairs (community_id, tournament_id);

create table tournament.matches (
  id uuid primary key default gen_random_uuid(),
  community_id uuid not null,
  tournament_id uuid not null,
  round_no integer not null,
  pair_a_id uuid not null,
  pair_b_id uuid not null,
  score_a integer,
  score_b integer,
  status text not null default 'scheduled',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint matches_tournament_fk foreign key (community_id, tournament_id)
    references tournament.tournaments (community_id, id) on delete cascade,
  constraint matches_pair_a_fk foreign key (community_id, pair_a_id)
    references tournament.pairs (community_id, id) on delete restrict,
  constraint matches_pair_b_fk foreign key (community_id, pair_b_id)
    references tournament.pairs (community_id, id) on delete restrict,
  constraint matches_community_id_unique unique (community_id, id),
  constraint matches_distinct_pairs check (pair_a_id <> pair_b_id),
  constraint matches_status_check check (status in ('scheduled', 'played', 'cancelled')),
  constraint matches_score_range check (
    (score_a is null or score_a between 0 and 99) and
    (score_b is null or score_b between 0 and 99)),
  constraint matches_not_tied check (
    not (status = 'played' and score_a is not null and score_b is not null
         and score_a = score_b)),
  constraint matches_round_non_negative check (round_no >= 0)
);

create index matches_community_tournament_idx
  on tournament.matches (community_id, tournament_id);
create index matches_pair_a_idx on tournament.matches (pair_a_id);
create index matches_pair_b_idx on tournament.matches (pair_b_id);

grant usage on schema tournament to bm2_app;
grant select, insert, update, delete on all tables in schema tournament to bm2_app;
