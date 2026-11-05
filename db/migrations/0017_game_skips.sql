-- 0017: which player sat out a specific game.
--
-- v1 kept `scheduled_games.skipped_player_refs`. v2 needs the same fact in a
-- relational row because standings and rating ingest must exclude exactly the
-- players the host skipped, without cancelling the whole game.

create table session.game_skips (
  community_id uuid not null,
  session_id uuid not null,
  round_no integer not null,
  court_no integer not null,
  player_id uuid not null,
  created_at timestamptz not null default now(),
  constraint game_skips_session_fk foreign key (community_id, session_id)
    references session.sessions (community_id, id) on delete cascade,
  constraint game_skips_player_fk foreign key (community_id, player_id)
    references player.players (community_id, id) on delete cascade,
  constraint game_skips_game_unique
    primary key (community_id, session_id, round_no, court_no, player_id),
  constraint game_skips_round_court_non_negative
    check (round_no >= 0 and court_no >= 0)
);

create index game_skips_community_session_idx
  on session.game_skips (community_id, session_id);

grant select, insert, update, delete on session.game_skips to bm2_app;
