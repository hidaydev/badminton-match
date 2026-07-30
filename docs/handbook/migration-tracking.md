# Migration Tracking

Last updated: 2026-07-30

All 53 original migrations (000001–000053) have been squashed into 3 files:

| File | Contents |
|------|----------|
| `20260616_000001_schema.sql` | All DDL in final state: tables, indexes, constraints, triggers, grants |
| `20260616_000002_functions.sql` | All 26 functions in final form with grants |
| `20260616_000003_seeds.sql` | Legacy backfill, identity seed, tournament seed, data fix, parity/smoke checks |
| `20260727_000001_drop_redundant_indexes.sql` | Drops redundant indexes already covered by UNIQUE constraints |

The original migration history (function rewrites, errcode flip-flops, grant
adjustments, UUID phase A/B/C) is preserved in git history but no longer
present as individual migration files.
