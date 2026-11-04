-- 0012: finish the tournament schema for both formats.
--
-- v2's 0003 modelled only the classic core: no header date/version/format, no
-- group membership, no stable per-tournament match key, and the knockout pair
-- references were NOT NULL even though an undecided bracket slot starts empty.
-- The team format (6 teams x 6 classes, 3 partai per team-match) had no tables
-- at all. This mirrors the v1 relational model so both formats round-trip
-- without a JSON blob, with community_id on every row and composite FKs.

alter table tournament.tournaments
  add column event_date date not null default current_date,
  add column version integer not null default 1,
  add column format text not null default 'classic',
  add constraint tournaments_version_positive check (version > 0),
  add constraint tournaments_format_check check (format in ('classic', 'team'));

alter table tournament.matches
  alter column pair_a_id drop not null,
  alter column pair_b_id drop not null,
  add column phase text not null default 'group',
  add column group_id text,
  add column pic_name text,
  add column match_key text,
  add column match_order integer not null default 0,
  add constraint matches_phase_check
    check (phase in ('group', 'qf', 'sf', '3rd', 'final')),
  add constraint matches_group_id_check
    check (group_id is null or group_id in ('A', 'B', 'C', 'D'));

create unique index matches_tournament_key_unique
  on tournament.matches (community_id, tournament_id, match_key);

-- Classic group membership: which pair sits in which slot of A-D.
create table tournament.groups (
  community_id uuid not null,
  tournament_id uuid not null,
  group_id text not null,
  pair_id uuid not null,
  position integer not null,
  constraint groups_tournament_fk foreign key (community_id, tournament_id)
    references tournament.tournaments (community_id, id) on delete cascade,
  constraint groups_pair_fk foreign key (community_id, pair_id)
    references tournament.pairs (community_id, id) on delete restrict,
  constraint groups_group_id_check check (group_id in ('A', 'B', 'C', 'D')),
  constraint groups_position_check check (position between 0 and 3),
  constraint groups_pk primary key (tournament_id, group_id, position)
);

create index groups_community_tournament_idx
  on tournament.groups (community_id, tournament_id);

-- Team format: the six teams, their roster with class, the team-matches and
-- the three partai inside each one.
create table tournament.teams (
  id uuid primary key default gen_random_uuid(),
  community_id uuid not null,
  tournament_id uuid not null,
  seed integer not null,
  team_name text not null,
  constraint teams_tournament_fk foreign key (community_id, tournament_id)
    references tournament.tournaments (community_id, id) on delete cascade,
  constraint teams_seed_check check (seed between 1 and 6),
  constraint teams_name_not_blank check (btrim(team_name) <> ''),
  constraint teams_community_id_unique unique (community_id, id)
);

create unique index teams_tournament_seed_unique
  on tournament.teams (community_id, tournament_id, seed);
create unique index teams_tournament_name_unique
  on tournament.teams (community_id, tournament_id, team_name);

create table tournament.team_players (
  id uuid primary key default gen_random_uuid(),
  community_id uuid not null,
  team_id uuid not null,
  player_name text not null,
  player_id uuid,
  cls text not null,
  constraint team_players_team_fk foreign key (community_id, team_id)
    references tournament.teams (community_id, id) on delete cascade,
  constraint team_players_player_fk foreign key (community_id, player_id)
    references player.players (community_id, id) on delete restrict,
  constraint team_players_cls_check
    check (cls in ('A+', 'A', 'B+', 'B', 'C+', 'C')),
  constraint team_players_name_not_blank check (btrim(player_name) <> '')
);

create unique index team_players_team_cls_unique
  on tournament.team_players (team_id, cls);

create table tournament.team_matches (
  id uuid primary key default gen_random_uuid(),
  community_id uuid not null,
  tournament_id uuid not null,
  phase text not null,
  match_order integer not null,
  match_key text not null,
  team_a_id uuid,
  team_b_id uuid,
  courts text[] not null default array['Court 12', 'Court 13', 'Court 14'],
  constraint team_matches_tournament_fk foreign key (community_id, tournament_id)
    references tournament.tournaments (community_id, id) on delete cascade,
  constraint team_matches_team_a_fk foreign key (community_id, team_a_id)
    references tournament.teams (community_id, id) on delete restrict,
  constraint team_matches_team_b_fk foreign key (community_id, team_b_id)
    references tournament.teams (community_id, id) on delete restrict,
  constraint team_matches_phase_check check (phase in ('group', 'final')),
  constraint team_matches_courts_check check (array_length(courts, 1) = 3),
  constraint team_matches_community_id_unique unique (community_id, id)
);

create unique index team_matches_tournament_key_unique
  on tournament.team_matches (community_id, tournament_id, match_key);

create table tournament.team_partai (
  id uuid primary key default gen_random_uuid(),
  community_id uuid not null,
  team_match_id uuid not null,
  partai_index integer not null,
  score_a integer,
  score_b integer,
  constraint team_partai_match_fk foreign key (community_id, team_match_id)
    references tournament.team_matches (community_id, id) on delete cascade,
  constraint team_partai_index_check check (partai_index between 0 and 2),
  constraint team_partai_score_range check (
    (score_a is null or score_a between 0 and 99) and
    (score_b is null or score_b between 0 and 99)),
  constraint team_partai_scores_together check ((score_a is null) = (score_b is null))
);

create unique index team_partai_match_index_unique
  on tournament.team_partai (team_match_id, partai_index);

grant select, insert, update, delete on all tables in schema tournament to bm2_app;
