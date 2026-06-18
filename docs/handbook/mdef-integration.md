# MDEF Integration

## Current reality

`MDEF` and `badminton-match` are different products with different purposes.

### `badminton-match`

Owns:

- session configuration
- operational players inside a session
- schedule generation
- live scores and played state
- tournament operations

### `MDEF`

Owns:

- canonical players
- alias resolution
- historical match history
- ELO and analytics

## Current workflow

At the moment, the integration is manual.

Historically:

1. publish session in `badminton-match`
2. copy the published session payload or compatible export
3. paste into `MDEF`
4. `MDEF` parses session results and computes ratings

After the Supabase migration:

- `badminton-match` no longer needs Google Sheets for the main session flows
- `MDEF` is intentionally left untouched for now
- manual JSON handoff is acceptable short-term

## Key constraint

`MDEF` should not force the internal schema of `badminton-match`.

The correct integration boundary is:

- exported session result payload

not:

- shared operational tables

## Recommended long-term boundary

### Short-term

- manual JSON copy/paste from `badminton-match`
- no `MDEF` code changes

### Medium-term

- formal `session_export` payload version
- stable export record from a `bm`-owned boundary

### Long-term

- optional direct import flow into `MDEF`
- still without forcing shared core tables

## Why shared tables are not ideal yet

Current saved-state models differ:

- `badminton-match` stores richer operational session state
- `MDEF` stores reduced analytical history and canonical player records

If both apps share core tables too early, one app will distort the other.

## Better compromise

Use the same Supabase project, but:

- separate schema for `badminton-match` operational data
- separate schema for `MDEF`
- a small export/import boundary between them

This keeps ownership clean while still allowing shared backend operations.
