-- 0014: the 0010 side constraint rejected every singles game.
--
-- `null is distinct from null` is false, so a game with one player on a side
-- (side_a2 and side_b2 both null) — the case 0010 itself documents as valid —
-- failed the check. So did an empty scheduled game. The replacement states the
-- real rules with explicit null guards: a player never appears on both sides
-- and never twice on one side, while an empty slot stays legal.

alter table session.games drop constraint games_distinct_sides;

alter table session.games add constraint games_distinct_sides check (
  (side_a1 is null or side_b1 is null or side_a1 <> side_b1) and
  (side_a1 is null or side_b2 is null or side_a1 <> side_b2) and
  (side_a2 is null or side_b1 is null or side_a2 <> side_b1) and
  (side_a2 is null or side_b2 is null or side_a2 <> side_b2) and
  (side_a1 is null or side_a2 is null or side_a1 <> side_a2) and
  (side_b1 is null or side_b2 is null or side_b1 <> side_b2)
);
