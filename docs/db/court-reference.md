# The court reference: a register, a materialised row, and one open question

> **DB-11** asked for `games_court_fk` and `game_skips_court_fk`. Both exist since
> `0056_court_foreign_keys.sql`. The question the key cannot answer, how many
> courts a session has, stays open and needs a product decision.

## What the schema says now

| Object | What it is |
|---|---|
| `session.courts` | One row per court of a session: `court_index`, `court_name`, `start_time`, `end_time`, and `declared` |
| `session.courts.declared = true` | A register the session ships with. The v1 import writes these; every row that existed before `0056` was marked declared by the backfill, because the import was the only writer |
| `session.courts.declared = false` | A row materialised from a game. `games_court_materialise` writes it from the session's own `start_time` and `slot_minutes` before the row is inserted |
| `games_court_fk` | `session.games (community_id, session_id, court_no)` → `session.courts (community_id, session_id, court_index)`, `deferrable initially deferred`, `on delete no action` |
| `game_skips_court_fk` | The same key from `session.game_skips`. A skip's court is its game's court, so no second materialising trigger is needed |

The guard from `0053` is still there and now reads `declared`: a session with a
declared register refuses a game on a coordinate outside it (`23503`), and a
session without one accepts any coordinate. `courts_court_still_in_use` still
refuses to delete or renumber a court a game uses.

Deferred keys, not immediate ones: a session delete removes its courts and its
games in one statement, and the check then sees the end state. `restrict` would
have been checked immediately even on a deferrable key.

## The backfill, and why it is safe to rerun

`0056` inserts one court row per coordinate a game already uses and has no row
for, taking the times from the session. Existing register rows are untouched
(`on conflict (community_id, session_id, court_index) do nothing`). A game in a
session with no register is the common case: every v2 session before this
migration.

Measured on the local clusters on 2026-11-11, before the migration:
`bm2_dev` 288 sessions, 0 courts, 266 games without a court row; `bm2_e2e`
10 sessions, 0 courts, 12 games without one; `bm2_explore`, imported from v1,
41 sessions, 126 courts and 929 games with none missing. A copy of `bm2_dev`
migrated to `0056` came out with 166 court rows (one per distinct coordinate),
0 games without a court row, and the key in place. Those are the rows the
backfill exists for; without it the key would fail on the first of them.

## What a reader must not assume

- A materialised court's `start_time`/`end_time` is the session's first slot, not
  a real allocation. It exists to make the coordinate real, not to describe the
  court's day. Nothing in the application reads it.
- The register is not a schedule. Deleting a register row a game uses is still
  refused; the games have to move or go first.
- `declared` is set by the writer, not derived: an import re-run marks the rows
  it upserts declared (`tools/import/main.nim`), which is what makes a rerun
  able to turn a materialised row into a register row.

## The open half

The key proves a court **exists**. It cannot say a coordinate is **valid**. A
session that has four courts will still accept a game on court 99 by
materialising a fifth, because nothing declares how many courts the session has.

Closing that needs a product decision, not a schema tweak:

1. does a session declare its courts when it is created (a count, a set, names)?
2. is the ceiling enforced on the API writer, the import, or both?
3. what happens to an existing session whose games are already outside such a
   ceiling?

Until those are answered, the honest statement is: the coordinate is always
real, and whether it should exist is unchecked. It is recorded in ADR-017 and in
the release criteria as the remaining part of DB-11.
