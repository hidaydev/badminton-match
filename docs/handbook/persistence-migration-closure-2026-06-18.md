# Persistence Migration Closure 2026-06-18

This document closes the main persistence migration arc for `badminton-match`.

## The three eras

### Era 1: Google Apps Script and Google Sheets

Original persistence model:

- Google Apps Script endpoint
- Google Sheets as the backing store
- snapshot-style rows

Why it worked:

- simple to ship
- matched the app’s snapshot-oriented UI model
- low operational overhead in the beginning

Why it became limiting:

- weak relational integrity
- expensive list/stat scans
- hard to evolve safely
- no strong concurrency model
- no clean long-term backend target

### Era 2: `badminton_match` snapshot-first Supabase landing zone

First Supabase migration target:

- schema: `badminton_match`

Purpose:

- replace Google Sheets without forcing a redesign
- preserve app behavior
- land existing session and tournament shapes in Postgres quickly

What it gave us:

- a stable migration bridge
- parity target for backfill and verification
- a way to prove Supabase viability before deeper normalization

Why it was not the end-state:

- still mostly snapshot-first
- not ideal for long-term stats/integrity
- not the cleanest production-target schema

### Era 3: `bm` normalized runtime schema

Final active runtime target:

- schema: `bm`

Why `bm` became the real destination:

- stronger relational structure
- better integrity constraints
- better stats/query surfaces
- cleaner session and tournament evolution path
- can still preserve compatibility snapshot contracts for the UI

## What changed across the arc

### From Google Sheets to `badminton_match`

Main change:

- storage backend moved from Apps Script/Sheets to Supabase/Postgres

Design principle:

- keep product behavior stable first

### From `badminton_match` to `bm`

Main change:

- architecture moved from snapshot-landing compatibility to normalized runtime ownership

Design principle:

- make `bm` the schema we would actually want to live with long-term

## What is true now

Current operational truth:

- the app runtime is `bm`-first
- `badminton_match` is no longer the conceptual target
- `badminton_match` mainly survives as migration history, compatibility, and parity context
- Google Sheets is no longer part of the active local runtime story

## What remains intentionally

We did not delete everything older.

What still exists on purpose:

- historical migrations
- compatibility functions
- parity-oriented snapshot surfaces
- legacy identity carriers on some tables

Why this is acceptable:

- safer rollout
- easier local verification
- lower migration risk

## Closure statement

The important migration decision is now complete:

- `badminton-match` has moved off Google Sheets as its active direction
- `badminton_match` served as the landing bridge
- `bm` is the real primary schema going forward

The remaining work is not “finish the migration from scratch”.
The remaining work is:

- cleanup
- documentation
- compatibility reduction when safe
- future hardening if and when production rollout needs it

## Practical conclusion

If someone asks which persistence layer matters now, the answer is:

- active runtime target: `bm`
- historical bridge: `badminton_match`
- old origin: Google Sheets / Apps Script

That is the final mental model to carry forward.
