-- 0034: the cutover runs `majadu-import etl` as bm2_etl, but 0015 only granted
-- the import schema, so the first insert into platform.community or
-- player.players failed with "permission denied for schema". The cutover stops
-- the v1 site before that step (cutover.sh:270-273), so the failure leaves
-- production down instead of rolling back.
--
-- The grant set follows the loader's statements in tools/import/main.nim and the
-- modules it calls: USAGE on every schema it touches, SELECT on every relation
-- it reads, INSERT and UPDATE on every table it writes. DELETE appears only
-- where the loader rewrites rows itself, so a rerun stays idempotent:
-- session.game_sets and session.game_skips are cleared per game before they are
-- written again, rating.events and rating.player_state are cleared by the
-- rating rebuild, and achievement.earned loses the badges the reconciliation no
-- longer qualifies. No TRUNCATE, no DDL and no ownership: the loader can neither
-- alter nor drop anything.

grant usage on schema platform, player, session, community, rating, tournament,
  achievement to bm2_etl;

-- platform: the import creates the community and reads the config, the config
-- version and the cutover marker. A populated community is never rewritten.
grant select on platform.config, platform.config_version,
  platform.cutover_state to bm2_etl;
grant select, insert on platform.community to bm2_etl;

-- player: the roster and its aliases are the first domain the import writes.
-- Aliases are only inserted (`on conflict do nothing`), never updated.
grant select, insert, update on player.players to bm2_etl;
grant select, insert on player.aliases to bm2_etl;

-- session: headers, courts, participants and games are upserted. Sets and skips
-- are rewritten per game, and the rating rebuild and the achievement backfill
-- read the board through game_sets, game_skips and the game_results view.
grant select, insert, update on session.sessions, session.courts,
  session.participants, session.games to bm2_etl;
grant select, insert, delete on session.game_sets, session.game_skips to bm2_etl;
grant select on session.game_results to bm2_etl;

-- community: only the L2 settings row is read, for the rating parameters.
grant select on community.settings to bm2_etl;

-- tournament: every header and child table is upserted, and the rating and
-- achievement paths read the same rows back.
grant select, insert, update on tournament.tournaments, tournament.pairs,
  tournament.groups, tournament.matches, tournament.teams,
  tournament.team_players, tournament.team_matches,
  tournament.team_partai to bm2_etl;

-- rating: sources, levels and snapshots are copied; the rebuild recomputes
-- events and player state from the sessions just imported.
grant select, insert, update on rating.sources, rating.levels,
  rating.snapshots to bm2_etl;
grant select, insert, update, delete on rating.events,
  rating.player_state to bm2_etl;

-- achievement: definitions are read, earned rows are inserted, and the
-- reconciliation deletes the ones the imported facts no longer qualify for.
grant select on achievement.definitions to bm2_etl;
grant select, insert, delete on achievement.earned to bm2_etl;
