# tools/fixtures

Deterministic synthetic data generator for the v1 schema (`bm`). T-099.

There is no production data here: player names are made up, scores are randomized
from a seed, and every timestamp is computed from a fixed epoch
(`2026-09-01T00:00:00Z`), not the wall clock. The same seed always produces a
byte-identical SQL file.

## Usage

```sh
nim c --hints:off -o:.cache/bin/fixtures tools/fixtures/main.nim
.cache/bin/fixtures --seed 7 --out ops/dev/v1/fixtures
```

Default output: `ops/dev/v1/fixtures/v1-fixtures.sql`. `--out` also accepts a
file name ending in `.sql`.

Applying it to a v1 database already restored from `ops/dev/v1/schema.sql`:

```sh
psql -v ON_ERROR_STOP=1 -d bm_v1_dev -f ops/dev/v1/fixtures/v1-fixtures.sql
```

The file starts with `truncate … restart identity cascade`, so it is safe to run
repeatedly on the same dev database.

## Contents

12 players, 2 sessions (published + draft), 8 scheduled games (5 with status
played), 5 rating events + 20 deltas, 1 classic tournament (6 pairs, group +
knockout), and 1 team tournament (4 teams, 3 matches). All `bm` tables are
populated, including `rating_config`, `rank_point_levels`, `outbox_events`, and
`idempotency_keys`.

## Determinism

- PRNG: SplitMix64 local to `main.nim` (not `std/random`), so the result does not
  depend on the Nim version.
- UUID: the `uuidFor(seed, namespace, index)` function; UUIDv4 in shape, but
  derived from the seed and the index, not from `gen_random_uuid()`.
- Time: only `dateAt`/`stampAt` from a fixed epoch; no `now()` is left to column
  defaults.
- Row order is fixed; there is no hash table iteration.

Quick verification:

```sh
.cache/bin/fixtures --seed 7 --out /tmp/fx-a
.cache/bin/fixtures --seed 7 --out /tmp/fx-b
shasum -a 256 /tmp/fx-a/v1-fixtures.sql /tmp/fx-b/v1-fixtures.sql
```

## Task runner integration (not done yet)

`task.d/dev-v1.sh` still uses `ops/dev/v1/seed.sql`. For `./task dev-v1` to use
this generator, a new entry is needed in `task` (the dispatcher is owned by the
platform lane) plus a `task.d/fixtures.sh` script; both are deliberately left
unchanged in T-099.