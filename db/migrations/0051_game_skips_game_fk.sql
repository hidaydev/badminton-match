-- 0051: a skip belongs to a game that exists.
--
-- The schedule grid is a pair of integers, and `session.game_skips` stored that
-- pair with no reference to `session.games`. A skip could name a coordinate no
-- game ever used, and deleting a game left its skips behind: the row then
-- described a player sitting out a game that does not exist. The sets already
-- hang off the game through `game_sets_match_fk`; skips did not.
--
-- The court reference the finding asked for as well is deliberately absent.
-- `session.courts` has no writer in v2: the session model never creates a court
-- row, so every game the API wrote to bm2_dev (266) and bm2_e2e (12) has no
-- court to point at, and only the v1 import fills the table. A foreign key to
-- it would reject the schedule writer instead of a bad coordinate. The evidence
-- and the decision are recorded in docs/DECISIONS.md (DB-11).
alter table session.game_skips
  add constraint game_skips_game_fk
  foreign key (community_id, session_id, round_no, court_no)
  references session.games (community_id, session_id, round_no, court_no)
  on delete cascade;
