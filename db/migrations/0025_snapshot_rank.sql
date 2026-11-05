-- 0025: rating.snapshots kept the points of a board row but not its rank.
--
-- The rank-streak badge is the longest run of event dates spent at rank 3 or
-- better, and a rank cannot be reconstructed from points alone: ties share a
-- rank and the board window moves. Without the placement, v2 has no history to
-- measure a streak against, so the daily snapshot records it from now on.
--
-- The column is nullable on purpose. Rows written before this migration have no
-- recorded rank, and inventing one would claim a placement the board never
-- showed. A NULL rank simply does not contribute to a streak.

alter table rating.snapshots add column rank integer;