-- 0041: drop the session indexes a stricter one already covers.
--
-- `session.sessions` is unique on `(community_id, id)`, so a `session_id`
-- determines its community: a second index that leads with `community_id,
-- session_id` adds nothing to the session-id lookup and costs one entry per
-- write on the hottest table. `games_round_court_unique` is the same rule as
-- `games_identity_unique` under another name, which also made a unique
-- violation ambiguous for the error mapping.
--
-- PostgreSQL 18 can use a skip scan for a community-only lookup through an
-- index whose first column is `community_id`.
alter table session.games drop constraint if exists games_round_court_unique;

drop index if exists session.courts_community_session_idx;
drop index if exists session.participants_community_session_idx;
drop index if exists session.game_skips_community_session_idx;
drop index if exists session.links_community_session_idx;
