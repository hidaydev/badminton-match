-- 0032: relations created from now on reach the application role without a
-- hand-written grant.
--
-- 0029 added session.game_sets and the session.game_results view without grants,
-- and 0030 had to add them after the fact, because the first request for the
-- board got "permission denied for view game_results" and answered 500. The
-- `on all tables in schema ...` grants in 0001/0002/0004/0005/0015 only cover
-- objects that already existed, so each new relation silently depends on its
-- author remembering a grant line.
--
-- Default privileges bind to the role that creates the object, and migrations
-- run as bm2_owner (ops/db/roles.sql, MAJADU_OWNER_DSN), so no `for role` is
-- needed here. Granting on tables covers views too, which is the case that
-- broke in 0029. Existing objects are untouched.
--
-- These defaults only add. Append-only tables still need their own
-- `revoke update, delete` right after creation, as player.merge_log
-- (0001_core.sql:210-211) and account.audit (0004_platform.sql:137-138) do.

alter default privileges in schema platform, session, player, community, rating,
  achievement, import
  grant select, insert, update, delete on tables to bm2_app;

alter default privileges in schema platform, session, player, community, rating,
  achievement, import
  grant usage, select on sequences to bm2_app;