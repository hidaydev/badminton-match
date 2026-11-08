# tools/import

One-shot ETL from the v1 database (`bm_staging`) to v2. T-064.

## Status

| Domain | v1 source | v2 target | State |
|---|---|---|---|
| Players | `bm.players` | `player.players` | done |
| Aliases | `bm.player_aliases` | `player.aliases` | done |
| Sessions + courts | `bm.sessions`, `bm.session_courts` | `session.sessions`, `session.courts` | done |
| Participants | `bm.session_players` | `session.participants` | done |
| Schedule + scores | `bm.scheduled_games`, `bm.scheduled_game_players` | `session.games` | done |
| Skips per player | `bm.scheduled_games.skipped_player_refs` | `session.game_skips` | done |
| Rating | `bm.rating_sources` | `rating.sources` + recompute from sessions/tournaments | done (recompute numbers) |
| Classic tournaments | `bm.tournaments`, `bm.tournament_pairs`, `bm.tournament_groups`, `bm.tournament_matches` | `tournament.*` | done |
| Team tournaments | `bm.tournament_teams`, `bm.tournament_team_players`, `bm.tournament_team_matches`, `bm.tournament_team_match_games` | `tournament.*` | done |
| Badges | `bm.player_achievements` | `achievement.earned` + backfill | done |
| Snapshots | `bm.rank_snapshots` | `rating.snapshots` (v1 points) | done, for the movement arrows |

The `etl` command prints `skippedDomains` (now empty) and `verify` prints
`checkedDomains`. Do not read a "problems: 0" output as "the whole database
matches" while there are still domains that are not checked.

## Run

```sh
MAJADU_ETL_SOURCE_DSN=postgresql://.../bm_staging \
MAJADU_PG_DSN=postgresql://.../bm2 \
  .cache/bin/majadu-import etl --slug majadu --name "Majadu"

# due diligence: compare, do not trust
MAJADU_ETL_SOURCE_DSN=... MAJADU_PG_DSN=... \
  .cache/bin/majadu-import verify --slug majadu
```

- `--timezone` is optional; without it, the value is read from
  `community.default_timezone` in `platform.config`. There is no default in the
  code.
- `--dry-run` computes without writing.
- `MAJADU_IMPORT_COMMUNITY_ID` points at an existing community, for example when
  resuming an interrupted import.

Build the binary:

```sh
nim c -d:release -o:.cache/bin/majadu-import tools/import/main.nim
```

## Guaranteed properties

1. **Idempotent.** Every row written has an entry in `import.row_map`
   (`community_id`, `entity`, `old_id` → `new_id`). A second run uses the same
   ids and updates, instead of copying.
2. **One transaction for writes.** The source is only read; all writes to v2 sit
   in a single transaction per domain.
3. **Duplicate names are collapsed.** v2 requires a unique `canonical_name` per
   community; v1 does not. Two v1 rows with the same name become one player, and
   `collapsed` counts them, so they are not treated as a discrepancy.
4. **No memberships or links are created.** Import moves data, not access
   rights; users and share links are not carried over (T-064).
5. **Dates stay community dates.** `session_date` and `local_date` are copied as
   dates, not computed from UTC; `calendarDate` is used when an instant has to be
   translated, and the WIB day boundary is tested.
6. **Rating is recomputed, not copied.** v1 stores `rating_deltas` without point
   values (only team and win/loss), whereas v2 stores points per player. v1
   numbers therefore cannot be turned into v2 deltas. Only the source signature
   is imported (`rating.sources.finalized`); events, deltas, and `player_state`
   are recomputed by the v2 formula from the sessions that just came in, and
   `verify` compares what is genuinely comparable: game count, wins, losses per
   player. Differences caused by v1 policy (e.g. pre-season) are reported, not
   covered up.
7. **Placeholder participants are skipped.** v1 allows an empty
   `session_players.player_id`; v2 requires a real player. Such rows are counted
   in `skipped`, and a game side that contains only placeholders becomes empty.
8. **Snapshots are imported as movement history, not as a leaderboard source.**
   The v2 leaderboard is always recomputed from games; `rating.snapshots` rows
   only store v1 points per date so the up/down arrow has a comparison point on
   the previous day. After cutover, daily snapshots must still be written (e.g.
   `./task ranksnapshot`); without that, the arrow compares against the last
   imported snapshot.
9. **Tournament status is derived.** v1 has no status column: a tournament
   without match rows becomes `draft`, one whose scores are all filled becomes
   `completed`, the rest become `active`. `pic_player_id` becomes `pic_name`
   because v2 stores the name, and `phase` becomes `round_no` (group 0, qf 1,
   sf 2, 3rd 3, final 4).
10. **Badges are expanded, not copied.** v1 stores one row per ladder
    (`medal:games` with `value` 57); v2 stores one row per threshold already
    crossed (`games:50`). v1 rows are written first, then `backfill` adds the
    other thresholds with `do nothing`, so the v1 dates survive. The
    `tournament:<id>` event badge has no v2 counterpart; that row is counted in
    `skipped`.

## Test

The tests write to two databases, so point them at scratch databases:

```sh
MAJADU_IMPORT_TEST_SOURCE_DSN=postgresql://.../bm_staging \
MAJADU_IMPORT_TEST_DSN=postgresql://.../bm2_scratch \
  nim c -r -o:.cache/bin/import_test tools/import/tests/import_test.nim
```

Without those two variables, the suite is skipped (not silently passing: a
"skipped" message is printed).