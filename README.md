# badminton-match

`badminton-match` is a badminton operations app built for real session usage:
set up courts and players, generate balanced doubles schedules, publish a
shared live session, track played games and scores, manage a tournament, and
generate social-ready graphics.

This repo is the operational source app in the larger badminton toolset. It is
separate from `MDEF`, which is the historical ELO and analytics system.

## What the app does

### Session scheduling

- configure title, date, court count, court hours, and slot duration
- define exact player count
- add players with gender and tier
- add fixed match constraints
- generate balanced doubles schedules
- retry generation until a better schedule is found

### Shared live session

- publish a session and get a shared URL
- reload shared sessions from cloud storage
- mark games played
- enter scores
- swap players between games
- swap whole game slots
- mark players absent
- rename players inside the live session

### History and stats

- browse past sessions
- browse known players
- view player-level historical stats:
  wins, losses, points for/against, top partners, top opponents

### Tournament

- assign 16 pairs into 4 groups
- compute group standings
- propagate knockout bracket automatically
- score bracket matches
- generate podium and bracket media

### Social export

- create Instagram-style graphics from sessions and tournament results
- export standings, bracket, and post-ready visuals

## Current stack

- React 19
- TypeScript
- Vite
- Tailwind CSS v4
- Zustand
- TanStack React Query
- React Router
- PWA support via `vite-plugin-pwa`

## Backend status

This branch migrates the app away from Google Apps Script / Google Sheets and
onto Supabase.

Current backend target:

- same Supabase project as `MDEF`
- separate schema: `badminton_match`
- snapshot-first persistence model

Main migration SQL:

- [`supabase/migrations/20260616_000001_badminton_match_schema.sql`](supabase/migrations/20260616_000001_badminton_match_schema.sql)

## Quick start

### 1. Install dependencies

```bash
npm ci
```

### 2. Configure local environment

Copy `.env.local.example` to `.env.local` and fill in:

```bash
VITE_SUPABASE_URL=...
VITE_SUPABASE_KEY=...
```

### 3. Apply database migration

Run the SQL in:

- [`supabase/migrations/20260616_000001_badminton_match_schema.sql`](supabase/migrations/20260616_000001_badminton_match_schema.sql)

against your Supabase project.

### 4. Run the app

```bash
npm run dev
```

### 5. Verify build

```bash
npm run build
```

## Documentation map

Start here:

- [`docs/README.md`](docs/README.md)

Main docs:

- [`docs/handbook/product-overview.md`](docs/handbook/product-overview.md)
- [`docs/handbook/architecture.md`](docs/handbook/architecture.md)
- [`docs/handbook/data-model.md`](docs/handbook/data-model.md)
- [`docs/handbook/features-and-routes.md`](docs/handbook/features-and-routes.md)
- [`docs/handbook/supabase-migration.md`](docs/handbook/supabase-migration.md)
- [`docs/handbook/mdef-integration.md`](docs/handbook/mdef-integration.md)
- [`docs/handbook/roadmap.md`](docs/handbook/roadmap.md)
- [`docs/handbook/sql/20260616_000001_badminton_match_schema.sql`](docs/handbook/sql/20260616_000001_badminton_match_schema.sql)

Historical design notes from the earlier build-out are preserved under:

- [`docs/superpowers/`](docs/superpowers)

## Current migration status

Verified on the Supabase migration branch:

- create session
- publish session
- open shared session link
- mark played
- enter score
- sessions list
- player list
- player stats

Still pending:

- historical data backfill from old Google Sheets storage
- full tournament end-to-end verification after migration
- production security hardening
- long-term formal export surface for `MDEF`

## Project role in the bigger system

`badminton-match` should remain the operational source app:

- session planning
- live match operations
- tournament administration

`MDEF` should remain the analytics destination:

- canonical players and aliases
- match history
- ELO and longitudinal analytics

Short-term integration can remain manual via JSON handoff.

## Notes

- The root `README` previously contained only the default Vite template text.
- The app still contains earlier design/spec history under `docs/superpowers`.
- The Supabase migration is intentionally minimal-risk and snapshot-first, not
  a full relational redesign.
