-- 0019: v1 recorded two badge families that are not in the v2 catalog:
-- per-event tournament medals (`tournament:<uuid>`, carrying the event name)
-- and the rank-streak badge. Keep the row as it was, with its date, and stop
-- requiring a catalog definition so imported event medals are not dropped.

alter table achievement.earned
  add column meta jsonb not null default '{}'::jsonb;

alter table achievement.earned
  drop constraint earned_achievement_key_fkey;
