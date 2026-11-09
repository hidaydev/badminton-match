-- 0037: a frozen scoring rule must carry the numbers the board view casts.
--
-- `session.game_results` evaluates
-- `(s.scoring_rules->>'gamesToWin')::int` and
-- `(s.scoring_rules->>'pointsToWin')::int` for every game of the session. A
-- row with a string or a missing key therefore raises for the whole community
-- board, not just for the session that owns it. The shape is a write-time
-- invariant, so it belongs in the table.
alter table session.sessions
  add constraint sessions_scoring_rules_shape check (
    jsonb_typeof(scoring_rules) = 'object' and
    scoring_rules ? 'gamesToWin' and
    jsonb_typeof(scoring_rules->'gamesToWin') = 'number' and
    scoring_rules ? 'pointsToWin' and
    jsonb_typeof(scoring_rules->'pointsToWin') = 'number'
  );
