# Migration Tracking

All 53 original migrations (000001–000053) have been squashed into 3 files:

| File | Contents |
|------|----------|
| `20260616_000001_schema.sql` | All DDL in final state: tables, indexes, constraints, triggers, grants |
| `20260616_000002_functions.sql` | All 26 functions in final form with grants |
| `20260616_000003_seeds.sql` | Legacy backfill, identity seed, tournament seed, data fix, parity/smoke checks |

The original migration history (function rewrites, errcode flip-flops, grant
adjustments, UUID phase A/B/C) is preserved in git history but no longer
present as individual migration files.
