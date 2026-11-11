-- 0055: a played game carries a set, at insert as well as on transition.
--
-- 0054 refused the transition outside a draft but left the insert open. The
-- reason was the write order: the import and the marking feature both write the
-- game row before the set exists, and a per-statement check would refuse the
-- row while it is half written. The trigger is deferred to commit, so that
-- order still works inside one transaction, and what is refused is a shape that
-- commits on its own with no set.
--
-- What this closes: an insert into a session that is no longer a draft, which
-- is the shape the readers disagree about (the session page counts the game,
-- `session.game_results` answers `winner = ''`, the projection drops it). The
-- import now writes `cancelled` for an unscored v1 flag, and the only production
-- insert path is the import.
--
-- What this leaves alone, on purpose: `setPlayed` marks a game played in a
-- *draft* so a host can record the result later. That flag is the product
-- behaviour 0052 and `modules/session/schedule.nim` describe, and a draft that
-- holds it cannot be approved (`sessions_approval_needs_results`, 0052), so the
-- disagreement cannot persist into a rated session. Refusing it here would
-- remove the feature, which is a product decision, not a schema one.
--
-- The rule itself is unchanged: `session.played_game_needs_result()` decides.
-- Only the event list moves, and a constraint trigger cannot be altered in
-- place, so it is dropped and recreated. No data is touched.

drop trigger if exists games_played_needs_result on session.games;

create constraint trigger games_played_needs_result
  after insert or update of status on session.games
  deferrable initially deferred
  for each row
  execute function session.played_game_needs_result();
