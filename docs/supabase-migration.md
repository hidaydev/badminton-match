# Supabase Migration

Last updated: 2026-06-17

This document tracks the migration of `badminton-match` from Google Apps
Script / Google Sheets to Supabase.

## Goal

Move `badminton-match` to Supabase without changing the product model:

- same session flow
- same publish/share flow
- same shared-session operations
- same player-history behavior
- no `MDEF` changes yet

The migration is intentionally snapshot-first, not fully normalized.

## Architecture choice

### Supabase project

- same Supabase project as `MDEF`

### Schema boundary

- separate schema: `badminton_match`

This avoids forcing shared tables while still keeping both apps in one backend
project.

### Storage strategy

Use snapshot-centric tables first:

1. `badminton_match.sessions`
2. `badminton_match.tournaments`
3. `badminton_match.session_exports`

This preserves current app behavior and keeps migration risk low.

## Implemented

### Database layer

Migration file:

- [supabase/migrations/20260616_000001_badminton_match_schema.sql](/Users/sachiel/Projects/badminton-match/supabase/migrations/20260616_000001_badminton_match_schema.sql:1)

Added:

- schema `badminton_match`
- table `sessions`
- table `tournaments`
- table `session_exports`
- RPCs:
  - `bm_publish_session`
  - `bm_get_session`
  - `bm_list_sessions`
  - `bm_list_players`
  - `bm_get_player_stats`
  - `bm_publish_tournament`
  - `bm_get_tournament`

### Frontend query layer

The app query layer was switched from Apps Script fetches to Supabase RPC
calls while preserving the existing frontend data shapes.

Main file:

- [src/queries/endpoints.ts](/Users/sachiel/Projects/badminton-match/src/queries/endpoints.ts:1)

### Environment contract

Switched from:

- `VITE_APPS_SCRIPT_URL`

to:

- `VITE_SUPABASE_URL`
- `VITE_SUPABASE_KEY`

Example file:

- [.env.local.example](/Users/sachiel/Projects/badminton-match/.env.local.example:1)

## Verified

Verified against the live Supabase project on branch `supabase-migration`:

1. create a small test session
2. publish session
3. open shared session link
4. mark one game played
5. enter score
6. query Supabase directly for:
   - sessions list
   - player list
   - player stats

Observed:

- session persisted correctly
- shared-session writes persisted correctly
- list/stat read surfaces returned correct data

## Not yet verified

These are still open:

1. tournament flow end-to-end after migration
2. historical Google Sheets data backfill
3. production security hardening
4. formal export surface for future `MDEF` integration

## Current status

### What is true

- the main session feature set is now running on Supabase
- the app no longer depends on Google Sheets for the tested session flows
- the migration is viable

### What is not yet true

- this is not fully production-grade yet
- old Google Sheets data has not been migrated into Supabase
- security posture has not been tightened enough for a production claim

## Big plan

### Phase 1: backend migration

Status: done

- create Supabase schema and tables
- replace Apps Script query layer
- validate main session flows

### Phase 2: historical backfill

Status: next

Goal:

- move old Google Sheets session data into `badminton_match.sessions`

Work:

1. export raw historical session rows from the existing Google Sheets source
2. normalize into the current `CloudSnapshot` shape if needed
3. insert into `badminton_match.sessions`
4. verify:
   - sessions list
   - player list
   - player history
   - player stats

### Phase 3: tournament verification

Status: pending

Goal:

- confirm tournament persistence and reload behavior on Supabase

Work:

1. create/update group assignments
2. save tournament
3. reload tournament
4. set bracket scores
5. verify propagated bracket state persists correctly

### Phase 4: security hardening

Status: pending

Goal:

- make the backend safe enough for real production use

Work:

1. decide who is allowed to write:
   - sessions
   - tournament
   - shared-session score updates
2. review grants
3. add RLS or explicit public-write policy
4. verify failure behavior

### Phase 5: export surface for `MDEF`

Status: deferred

Goal:

- keep `MDEF` untouched for now, but prepare a cleaner handoff

Short-term:

- manual JSON copy/paste is acceptable

Later:

- stable export payload from `session_exports`
- optional URL-based export again if needed

### Phase 6: documentation baseline

Status: started

Goal:

- replace the placeholder repo docs with a usable system baseline

Delivered:

- root `README`
- architecture, data model, route, integration, and roadmap docs

Remaining:

- update docs after historical backfill
- update docs after tournament verification

## Google Sheets export reality

### Can this repo export the old Google Sheets data automatically right now?

Not from the repository alone.

What the repo still contains:

- old Apps Script source:
  [apps-script/Code.gs](/Users/sachiel/Projects/badminton-match/apps-script/Code.gs:1)

What the repo does **not** contain:

- Google service account credentials
- Google Sheets API credentials
- OAuth client setup for Sheets export
- an Apps Script deployment secret or authenticated export mechanism
- the actual spreadsheet identifier in a reusable export toolchain

So, unless data is still reachable through a live Apps Script endpoint you
control, historical export must come from one of these:

1. manual spreadsheet export
2. a temporary one-off script using your Google access
3. a direct Apps Script/Sheet dump performed outside this repo

### Practical implication for tomorrow

To do historical backfill, one of the following is needed:

- exported JSON/CSV from the old sheet
- access to the old sheet
- a working legacy Apps Script endpoint that can still list/fetch old records

## Recommended next step

Tomorrow:

1. identify the old data source still available
2. export historical session data
3. map it into `CloudSnapshot`
4. backfill `badminton_match.sessions`
5. verify stats against real history
