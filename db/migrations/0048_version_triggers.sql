-- 0048: every table that carries `updated_at` owns its version too.
--
-- Optimistic concurrency existed on sessions, games and tournaments, and was
-- absent on the tables a tournament editor writes: a match, a pair, a team and
-- a partai. Two hosts scoring the same match both succeeded and the later
-- write won silently. `sessions.updated_at` also depended on four hand-written
-- statements staying correct.
--
-- The shared `session.bump_version()` trigger now owns the bump for every table
-- with `updated_at`, so no writer has to remember either column. The rows that
-- did not have a version start at 1.
alter table tournament.matches
  add column version integer not null default 1;
alter table tournament.pairs
  add column version integer not null default 1,
  add column updated_at timestamptz not null default now();
alter table tournament.teams
  add column version integer not null default 1,
  add column updated_at timestamptz not null default now();
alter table tournament.team_partai
  add column version integer not null default 1,
  add column updated_at timestamptz not null default now();
alter table player.players
  add column version integer not null default 1;
alter table community.settings
  add column version integer not null default 1;
alter table rating.levels
  add column version integer not null default 1;
alter table rating.player_state
  add column version integer not null default 1;

create trigger sessions_bump_version
  before update on session.sessions
  for each row execute function session.bump_version();

create trigger tournaments_bump_version
  before update on tournament.tournaments
  for each row execute function session.bump_version();

create trigger matches_bump_version
  before update on tournament.matches
  for each row execute function session.bump_version();

create trigger pairs_bump_version
  before update on tournament.pairs
  for each row execute function session.bump_version();

create trigger teams_bump_version
  before update on tournament.teams
  for each row execute function session.bump_version();

create trigger team_partai_bump_version
  before update on tournament.team_partai
  for each row execute function session.bump_version();

create trigger players_bump_version
  before update on player.players
  for each row execute function session.bump_version();

create trigger community_settings_bump_version
  before update on community.settings
  for each row execute function session.bump_version();

create trigger rating_levels_bump_version
  before update on rating.levels
  for each row execute function session.bump_version();

create trigger player_state_bump_version
  before update on rating.player_state
  for each row execute function session.bump_version();
