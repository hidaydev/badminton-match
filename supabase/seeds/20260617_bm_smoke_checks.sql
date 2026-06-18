-- BM direct-schema smoke checks for local app mode.
-- These should all succeed without errors.

-- Session list works in schema bm.
select *
from bm.list_sessions()
limit 3;

-- Player list works in schema bm.
select *
from bm.list_players()
limit 10;

-- Session fetch works for an existing id.
select bm.get_session('t647zv') is not null as has_session_t647zv;

-- Player stats works for a known canonical player.
select bm.get_player_stats('Rakha') is not null as has_rakha_stats;

-- Tournament fetch works for local tournament id.
select bm.get_tournament('tournament-2026-05-23-majadu') is not null as has_tournament_snapshot;
