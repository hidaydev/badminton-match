-- 0022: the rank-streak badge v1 awarded per player (`rank_streak:<value>`)
-- has no catalog definition, so its shelf entry had no ladder to render.
-- Give the family the v1 rungs; the earned value is the player's best run,
-- and a value between rungs counts the rungs below it.
insert into achievement.definitions (key, category, threshold) values
  ('rank_streak:3',  'rank', 3),
  ('rank_streak:5',  'rank', 5),
  ('rank_streak:8',  'rank', 8),
  ('rank_streak:12', 'rank', 12),
  ('rank_streak:16', 'rank', 16)
on conflict (key) do nothing;
