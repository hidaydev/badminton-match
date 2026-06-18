# BM Compatibility Surface 2026-06-18

This document explains which compatibility layers still exist and why.

## Why this document exists

The app runtime is already `bm`-first.
Even so, a few compatibility surfaces still exist intentionally.

The goal is to prevent accidental deletion of something that still serves a migration purpose.

## Compatibility layers still present

### `bm.get_session_snapshot_compat(text)`

Why it exists:

- the app session snapshot shape is still snapshot-driven
- the UI and publish flow still use the compatibility snapshot contract
- this gives a stable bridge from the normalized relational model back to the app payload shape

Current status:

- still needed

### Public RPC wrappers

Examples:

- `public.bm_*` wrappers added for compatibility

Why they exist:

- they protect older calling paths
- they allow transitional clients or local tooling to keep working while the runtime moves fully to `bm`

Current status:

- transitional
- safe to keep while migration settles

### Historical `badminton_match` references

Why they exist:

- migration history
- parity verification
- legacy data backfill

Current status:

- historical only
- should not be used by new runtime paths

## What is no longer considered an active compatibility layer

These are now part of the real architecture, not just migration crutches:

- `bm.sessions.internal_id`
- `bm.tournaments.internal_id`
- `bm.publish_session(...)` internal-id-first write path
- child internal UUID relation columns
- composite identity constraints and sync triggers

## Removal criteria

Only remove compatibility surfaces when all of these are true:

1. no active app/runtime path depends on them
2. no local maintenance workflow depends on them
3. the replacement path is documented and stable
4. deletion would not reduce rollback safety in the near term

## Recommended future cleanup order

1. keep historical migrations untouched
2. review `public` wrappers one by one
3. keep `*_compat` functions until the app contract itself is deliberately changed
4. only then consider a smaller compatibility surface
