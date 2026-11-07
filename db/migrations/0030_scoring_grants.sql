-- 0030: 0029 added session.game_sets and the session.game_results view but no
-- grants, and every grant in 0001-0028 ran before those objects existed. The
-- application role therefore opened a board and got "permission denied for view
-- game_results", which surfaced as a 500 on the rankings route. Sets are written
-- by the app when a score is recorded, so they need the write grants too.
grant select, insert, update, delete on session.game_sets to bm2_app;
grant select on session.game_results to bm2_app;