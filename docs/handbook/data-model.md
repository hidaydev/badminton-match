# Data Model: Single Source of Truth

This document is the source of truth for the **v2 database** (`bm2`) and the data shapes
used by the API. Everything below comes from the migration files in the repo; there are no
claims from a VPS dump or the v1 schema.

- Migrations: `db/migrations/0001_core.sql` … `0035_audit_occurred_at.sql` (35 files;
  `0035` adds the `account.audit` occurred_at index, `0034` grants the ETL role,
  `0033` adds `session.links.legacy_id_ok`, `0032` adds default privileges
  for the application role, and `0030` grants access to `session.game_sets` and the
  `session.game_results` view).
- Seeds: `db/seeds/platform_config.sql`, `db/seeds/achievement_definitions.sql`.
- Ledger: `tools/dbtools/main.nim:6-16` creates `dbtools.schema_migrations` and
  `dbtools.seed_files` (checksum per file).
- The database names `bm2_dev`/`bm2_e2e` come from the tooling, not from SQL:
  `.github/workflows/ci.yml`, `task.d/e2e.sh`.

There is no `bm` schema, JSON snapshot table, `scheduled_games`, or v1 `rating_events` in
v2. Those names exist only in the v1 migration archive, which was removed from
the working tree; `git log --all -- docs/backend` still has it.

## 1. General rules

1. **Tenancy on every row.** Community-owned tables store `community_id` and
   use a composite FK `(community_id, id)` to their parent. One row cannot
   cross communities (`db/migrations/0001_core.sql:32-52`, `db/migrations/0003_tournament.sql:7-20`).
2. **UUIDs from the database.** Most PKs use `gen_random_uuid()`. The deliberate
   exceptions: `session.links.id` is filled by the application because it is used as the encryption
   AAD (`db/migrations/0001_core.sql:54-56`).
3. **Time.** `timestamptz` for process time; calendar dates use `date`
   (`session_date`, `event_date`, `local_date`, `taken_on`).
4. **Enums as CHECK**, not Postgres enum types: session status, role, tier, team class,
   tournament phase, and audit result.
5. **Least-privilege grants.** The application uses the `bm2_app` role, not owner. Evidence
   tables (`account.audit`, `player.merge_log`) may only `select`/`insert`
   (`db/migrations/0001_core.sql:203-211`, `db/migrations/0004_platform.sql:131-138`).

## 2. Tables per schema

### `platform`

| Table | Key columns/constraints | Migration |
|---|---|---|
| `platform.community` | `id`, globally unique `slug` + format `^[a-z0-9]…$`, `name`, `timezone`, `created_at` | `0001:9-19` |
| `platform.user` | unique `google_sub`, unique `email_hash`, `display_name`, `is_platform_owner` | `0001:21-30` |
| `platform.config` | PK `key`; `value_type` (`int`/`decimal`/`bool`/`string`/`json`), `value` JSONB, `min_value`/`max_value`, `scope` (`platform`/`community`), `description`, `since_version` | `0004:6-18` |
| `platform.config_version` | Singleton (`id boolean primary key default true`), `version bigint`; the config snapshot is cached per this value and reloaded when it changes | `0004:20-25` |
| `platform.idempotency_keys` | Unique `(user_id, key)`, `body_hash`, `status_code`, `response` JSONB, `expires_at` + index | `0004:27-39` |
| `platform.import_row_map` | PK `(community_id, source_table, source_key)` → `target_id`; v1→v2 ETL map | `0004:41-48` |
| `platform.ws_ticket` | unique `token_hash`, `channel_kind` (`session`/`share`), `channel_id`, `user_id` nullable with CHECK: the share channel may be anonymous, session requires a user; `expires_at`, `used_at` | `0004:50-64`, `0007` |
| `platform.cutover_state` | Singleton; `snapshot_sha256`, `snapshot_taken_at`, `etl_completed_at`, `completed_at`, `app_version`, `rows_imported` (0016) | `0004:66-73`, `0016` |
| `platform.outbox` | `topic`, `payload` JSONB, `created_at`, `processed_at`; currently only cleaned by the janitor, no event producer yet | `0004:121-128` |
| `platform.ops_token` | `name`, unique `token_hash`, `created_by`, `expires_at`, `revoked_at`, `last_used_at` | `0008:6-22` |

### `session`

| Table | Key columns/constraints | Migration |
|---|---|---|
| `session.sessions` | `community_id`, `title`, `session_date`, `start_time`, `slot_minutes > 0`, `status` ∈ `draft/locked/published/completed/archived`, `source` ∈ `manual/generator/legacy_snapshot`, `version > 0`, `approved_at`, `approved_by`; `scoring_preset` and `scoring_rules` JSONB (per-session format snapshot) | `0001:32-52`, `0006`, `0029` |
| `session.links` | `id` filled by the application, unique `code_hash`, `code_enc`, `key_id`, `created_by`, `revoked_at`, `expires_at`, `legacy_id_ok`; a partial index guarantees one live link per session | `0001:54-75`, `0033` |
| `session.courts` | `court_index >= 0`, unique `(session_id, court_index)`, `start_time < end_time` | `0001:77-93` |
| `session.games` | Unique `(session_id, round_no, court_no)` and `games_identity_unique` (0029) on `(community_id, session_id, round_no, court_no)`; status `scheduled/played/cancelled`; `version` bumped by the `session.bump_version()` trigger; `side_a1/a2/b1/b2` (0010) with composite FKs to `session.participants`; CHECK `games_distinct_sides` (0014); the old `score_a`/`score_b` are only the backfill and rollback path, no longer written by the application | `0001:95-134`, `0010:32-61`, `0014`, `0029` |
| `session.participants` | Unique `(session_id, player_id)`; `is_absent`; player FK `on delete restrict` | `0010:7-27` |
| `session.game_sets` | One row per set; `set_no` 1–9, `score_a`/`score_b` 0–99 and must not be a draw; unique `(session_id, round_no, court_no, set_no)`; composite FK to `session.games`, cascade; application grants in `0030` | `0029`, `0030` |
| `session.game_skips` | PK `(community_id, session_id, round_no, court_no, player_id)`; players skipped in one game; cascade with session and player | `0017` |

`session.game_results` is a view (not a table) that computes `sets_played`,
`sets_a`/`sets_b`, `points_a`/`points_b`, and `winner` per match from
`session.game_sets` with the session's `scoring_rules` (`0029`).

Note: `session.games` is a relational schedule, not a blob. The four side columns mean
singles uses one slot per side; a `NULL` slot is an empty position, not a player.
Since `0029`, one `session.games` row is one match containing 1..N sets, not
one pair of scores.

### `player`

| Table | Key columns/constraints | Migration |
|---|---|---|
| `player.players` | `canonical_name`, `canonical_key` generated (trim + lower + collapse whitespace) unique per community, nullable `tier` ∈ `D/D+/C/C+/B/B+/A/A+`, `gender` ∈ `M/F`, `user_id`; one owned player per user per community | `0001:136-160` |
| `player.claims` | `status` ∈ `pending/approved/rejected/released`; decision fields consistent with status; one `pending` and one `approved` per player | `0001:162-188` |
| `player.merge_log` | `source_id`, `target_id`, `rows_moved >= 0`, `actor_id`; append-only for the application | `0001:190-201` |
| `player.aliases` | `alias`, generated `alias_key`, unique `(community_id, alias_key)`, player FK cascade | `0009:7-25` |

### `rating` & `achievement`

| Table | Key columns/constraints | Migration |
|---|---|---|
| `rating.events` | `community_id`, `local_date`, `event_type` ∈ `session/tournament/manual`, `source_id` (session/tournament id), `point_entries` (number of player-game entries counted by that event), index `(community_id, local_date desc)` | `0002:8-20`, `0026` |
| `rating.player_state` | PK `(community_id, player_id)`, `games_played`, `wins`, `losses`; CHECK `games_played = wins + losses` | `0002:42-54`, `0026` |
| `rating.snapshots` | PK `(community_id, player_id, taken_on)`, `rating`, `rank` (nullable); points and rank per date, filled by ETL (v1 history) and `./task ranksnapshot`; source of the movement arrow and the `rank_streak` run | `0002:56-67`, `0025` |
| `rating.sources` | PK `(community_id, source_id)`, `kind` ∈ `session/tournament`, `finalized`, `finalized_at`; the sign-off survives rebuilds and makes revert refused | `0013:9-24` |
| `rating.levels` | PK `(community_id, kind)`, `champion_points`, `round_ratios` JSONB (`qf/sf/final/group/runner_up/participant`), `enabled`; kind `session/tournament_classic/tournament_team` | `0020` |
| `achievement.definitions` | PK `key`, `category`, `threshold >= 0`; include the `rank_streak` rung for the v1 medal display | `0002:69-74`, `0022` |
| `achievement.earned` | PK `(community_id, player_id, achievement_key)`, `meta` JSONB, `earned_at`; no FK to definitions so v1 event medals stay stored | `0002:76-86`, `0019` |

Points are not stored as a column. The board is computed at read time from session games and
tournament matches in a rolling window (v1 projection: one entry per source, best `best_n`);
that is the **only** points number exposed by the API. The per-game ledger (`rating.deltas`)
and the stored score (`player_state.rating`) were removed in `0026`: their values were only
used by ingest itself, and storing them forced a rebuild to replay events just to
reproduce numbers nobody reads. `rating.player_state` keeps only the played/won/lost
counters, while `rating.events.point_entries` stores how many player-game entries one event
counted (used by the rating source screen and the revert/rebuild reports). The player page takes
`points` from the board row
(`modules/rating/projection.nim`, `modules/rating/read.nim`, `apps/api/src/app.nim`).

### `tournament`

| Table | Key columns/constraints | Migration |
|---|---|---|
| `tournament.tournaments` | `name`, `status` ∈ `draft/active/completed/archived`, `event_date`, `version > 0`, `format` ∈ `classic/team` | `0003:7-20`, `0012:10-15` |
| `tournament.pairs` | `display_name`, `player_a_id`/`player_b_id` (must differ), unique `(community_id, id)` | `0003:22-41` |
| `tournament.matches` | `round_no`, nullable `pair_a_id`/`pair_b_id`, `phase` ∈ `group/qf/sf/3rd/final`, `group_id` ∈ `A–D`, `pic_name`, `match_key` unique per tournament, `match_order`, scores 0–99 with no draw when `played` | `0003:43-76`, `0012:17-31` |
| `tournament.groups` | PK `(tournament_id, group_id, position)`; `group_id` A–D, `position` 0–3 | `0012:34-50` |
| `tournament.teams` | `seed` 1–6, `team_name`; seed and name unique per tournament | `0012:54-70` |
| `tournament.team_players` | `player_name` (snapshot), nullable `player_id`, `cls` ∈ `A+/A/B+/B/C+/C`; unique `(team_id, cls)` | `0012:72-89` |
| `tournament.team_matches` | `phase` ∈ `group/final`, `match_order`, unique `match_key`, nullable `team_a_id`/`team_b_id`, `courts text[3]` (default `Court 12/13/14`) | `0012:91-113` |
| `tournament.team_partai` | `partai_index` 0–2, scores 0–99, `(score_a is null) = (score_b is null)`; unique `(team_match_id, partai_index)` | `0012:115-132` |

### `community`

| Table | Key columns/constraints | Migration |
|---|---|---|
| `community.membership` | PK `(community_id, user_id)`, `role` ∈ `member/host/admin`, per-user index | `0005:5-14` |
| `community.invite` | unique `token_hash`, `email_hash`, `role`, `created_by`, `expires_at`, `accepted_at` | `0005:16-30` |
| `community.join_request` | `status` ∈ `pending/approved/rejected`; `decided_at` consistent; one `pending` per `(community, user)` | `0005:32-48` |
| `community.settings` | PK `community_id`, `values` JSONB, `updated_at`; per-community override | `0005:50-55` |

### `auth` & `account`

| Table | Key columns/constraints | Migration |
|---|---|---|
| `auth.oauth_flows` | unique `state_hash`, `nonce_hash`, `code_verifier_enc`, `return_to`, `expires_at` + index | `0004:75-86` |
| `account.sessions` | `user_id`, unique `token_hash`, `created_at`, `last_seen_at`, `absolute_expires_at`, `revoked_at` | `0004:88-99` |
| `account.audit` | `occurred_at`, `actor_id`/`actor_role`, `community_id`, `action`, `target_kind`/`target_id`, `result` ∈ `allow/deny/error`, `request_id`, `before`/`after` JSONB; append-only | `0004:101-119` |

## 3. Constraints & rules that are easy to get wrong

- `session.games` must not be a draw when `status = 'played'` on the old `score_a`/`score_b`
  columns, which are now only the backfill/rollback path; new scores live in
  `session.game_sets` (`0001:111-117`, `0029`).
- The per-row version of `session.games` is bumped by a trigger, but **API OCC uses the session
  version** (`session.sessions.version`), see [`architecture.md`](architecture.md) §9.
- The same player must not appear twice in one game, and must not be on
  both sides; CHECK `games_distinct_sides` in version `0014` fixes `0010`, which rejected
  singles/empty games.
- `player.players.canonical_key` and `player.aliases.alias_key` use the same normalization;
  aliases are unique per community so two players do not answer to the same name.
- The name in `tournament.team_players.player_name` is a snapshot; `player_id` may be
  `NULL` for a player not yet registered.
- `rating.sources` is the only place for sign-off; `rating.events` no longer has a
  `finalized` column (moved by `0013`).
- `platform.ws_ticket` stores a hash, not a token; the `share` channel may have no user,
  the `session` channel may not (`0004:50-64`).

## 4. Configuration registry

All business numbers are read from `platform.config` + `community.settings` overrides.
Defaults are in `db/seeds/platform_config.sql`; keys and their types are locked in
`modules/platform/config/registry.nim`. A missing value, a wrong type, or a
`scope` that does not match the registry makes the process refuse to start
(`modules/platform/config/store.nim:50-78`). The `community.default_timezone` value
is checked against `pg_timezone_names` when the community is created and when settings
are written, so an unknown zone is rejected as `400`, not stored.

| Group | Key (seed default) |
|---|---|
| Community | `community.join_requests_enabled` (`false`), `community.invite_ttl_days` (`7`), `community.directory_enabled` (`false`), `community.default_timezone` (`Asia/Jakarta`) |
| Pagination | `api.page_size_default` (`100`), `api.page_size_max` (`500`), `api.page_offset_max` (`1000000`), `rank.board_limit` (`200`) |
| Points | `rating.session_base` (`250`), `rating.score_target` (`30`, fallback for sessions without a format snapshot), `rating.opponent_clamp` (`[0.5,1.5]`), `rating.window_weeks` (`12`), `rating.best_n` (`10`), `rating.thin_evidence_n` (`3`), `rating.tier_bands` (8 class bands: D 1000–1199 … A+ 2100–open) |
| Tournament | domain constant `PairCount = 16` (not config; 16 pairs is a format rule) |
| Security | `security.allowed_origins`, `security.rate_limit_per_minute` (`300`), `security.max_body_bytes` (`1048576`), `security.max_json_depth` (`16`), `security.join_request_rate` (`5`), `security.share_scrape_limit` (`120`) |
| Realtime | `ws.max_watchers_per_session` (`50`), `ws.max_watchers_per_ip` (`20`), `ws.max_watchers_process` (`500`), `ws.ticket_ttl_seconds` (`60`) |
| Login sessions | `session.absolute_days` (`30`), `session.idle_days` (`7`), `session.slot_minutes_default` (`30`), `auth.flow_ttl_minutes` (`10`) |
| Public links | `share.link_ttl_days` (`30`) |
| Retention | `janitor.retention_days` (`30`), `audit.retention_days` (`365`) |

`rating.tier_bands` is a **display/classification attribute**, not the result of the points
calculation: a player's tier is stored in `player.players.tier` and only changes through `PATCH player`.
Bands use the v1 class ranges with `max` (e.g. D 1000–1199, A+ 2100–open); the band
midpoint is used as the tier strength in the opponent multiplier. Tournament ladders
(`champion_points` and `round_ratios`) are stored in `rating.levels`, not in config:
that is data an operator fills through `./task levels` (list/set/clear), and a community
without a row for a format uses the per-game formula.

## 5. Data shape in the API vs frontend types

The API contract is the source of payload shape (`packages/contracts/openapi/*.yaml`). The
per-feature TypeScript types are local projections, not the SSOT:

- `apps/web/src/legacy/queries/types.ts`: `SessionMeta`, `PlayerStats`, and a
  re-export of `CloudSnapshot`.
- `apps/web/src/legacy/queries/endpoints.ts`: v1 payload adapter: `GameRow`,
  `TournamentMeta`, `RatingPlayer`, `RankPointsBoard`, `AchievementRow`.
- `apps/web/src/community/api.ts`: `CommunityConfig` (`value` + `source`
  `platform`/`community`).

Example session read shape (`GET /c/{slug}/sessions/{id}`):

```json
{
  "id": "uuid", "title": "…", "date": "YYYY-MM-DD",
  "startTime": "HH:MM", "slotMinutes": 30,
  "status": "draft", "version": 1,
  "participants": [{ "playerId": "uuid", "name": "…", "absent": false }],
  "games": [{ "round": 0, "court": 0, "sideA": ["uuid"], "sideB": [],
              "scoreA": null, "scoreB": null, "status": "scheduled" }]
}
```

Sources: `apps/api/src/app.nim` (`getSessionDetail`),
`apps/web/src/legacy/queries/endpoints.ts`.

## 6. What does not exist in v2

Do not carry names from the v1 document into this one:

| v1 | v2 |
|---|---|
| schema `bm`, migrations `000001`–`000023` | database `bm2`, migrations `0001`–`0035` |
| `scheduled_games`, `scheduled_game_players` | `session.games` + `session.participants` |
| `rating_events`, `rating_deltas`, `rating_players` | `rating.events`, `rating.player_state` (the delta ledger has no counterpart) |
| `player_achievements` | `achievement.earned` + `achievement.definitions` |
| session/tournament JSON snapshot | per-table relational columns |
| Glicko/absolute rating | relative points computed at read time |

v1 SQL archive (not the active schema): `git log --all -- docs/backend`.
