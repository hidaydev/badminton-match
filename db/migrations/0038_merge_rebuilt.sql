-- 0038: a merge records that it rebuilt the derived rating counters.
--
-- A merge rewrites the games that named the source player onto the target and
-- then replays the community ledger in the same transaction, so `games_played`
-- matches the history again. The flag makes that step visible in the history
-- row instead of looking like a plain row move.
alter table player.merge_log
  add column rebuilt boolean not null default false;
