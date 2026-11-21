-- 0058: the board and the achievement backfill look up absentees by community.
--
-- `modules/rating/projection.nim` and
-- `modules/achievement/infrastructure/backfill.nim` both open with
--
--   select session_id, player_id from session.participants
--    where community_id = $1::uuid and is_absent
--
-- and no index carries `is_absent`. `participants_community_player_idx
-- (community_id, player_id)` and `participants_session_player_unique
-- (session_id, player_id)` can both enter the community's rows, but neither can
-- narrow them to the absent ones, so the read returns every participant of the
-- community and filters in the executor. That happens on every board request,
-- not once a night.
--
-- The predicate is written to match the query text exactly, including its
-- `is_absent` without a comparison: `is_absent` is `boolean not null`, so
-- `where is_absent` and `where is_absent = true` are the same predicate and the
-- planner recognises the partial index for both. `community_id` is the indexed
-- column because both callers filter on it first; a session-scoped variant is
-- already served by `participants_session_player_unique`.
--
-- Partial, so a session where nobody is absent stores no entry and pays nothing
-- on insert; only the goalkeeper rows this query wants are indexed.
--
-- Plain, not `concurrently`: dbtools applies each pending file inside one
-- transaction (same reason as 0031 and 0057).
--
-- Down path: drop the index, nothing else depends on it.
--   drop index if exists session.participants_absent_idx;
-- Both callers fall back to the community scan they do today.

create index if not exists participants_absent_idx
  on session.participants (community_id)
  where is_absent;
