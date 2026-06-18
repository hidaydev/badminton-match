# Architecture

## High-level shape

The app is a client-heavy React application with three distinct layers:

1. local operational state
2. pure scheduling and tournament logic
3. remote persistence/query layer

## Frontend runtime

### Entry

- `src/main.tsx`
- `src/App.tsx`

`main.tsx` creates the React root and installs the React Query provider.

`App.tsx`:

- sets up routes
- defines route guards
- handles PWA update prompt
- supports hash-based shared-view snapshots

## State model

### Local app state: Zustand

Primary local state is in:

- `src/store/index.ts`

This store owns:

- session config
- players
- fixed matches
- last generated result
- published schedule state
- played games
- game scores
- cloud session id

This is the operational in-progress session state.

### Tournament state

There is also a tournament-specific local store file:

- `src/store/tournament.ts`

Current tournament pages are primarily driven through the query layer and
utility functions rather than this store alone.

## Query layer

Remote read/write access is wrapped in:

- `src/queries/endpoints.ts`
- `src/queries/sessions.ts`
- `src/queries/players.ts`
- `src/queries/tournament.ts`

The pages and components should depend on these query hooks rather than
embedding storage details directly.

## Domain logic

### Session generator

Main file:

- `src/generator/index.ts`

This is the core scheduling engine.

It tracks:

- play counts
- sit counts
- repeated partners
- repeated opponents

And it uses those counts to score and place candidate games.

### Tournament logic

Main file:

- `src/utils/tournament.ts`

This file owns:

- group match creation
- standings computation
- knockout bracket propagation
- group PIC assignment

### Operational mutations

Utility files:

- `src/utils/swap.ts`
- `src/utils/slotSwap.ts`
- `src/utils/standings.ts`

These support:

- player swaps
- slot swaps
- standings computation for live session views

## Layout structure

### Home shell

- `src/components/HomeLayout.tsx`

Used for:

- landing/home
- sessions
- player history
- tournament
- Instagram tools

### Session shell

- `src/components/SessionLayout.tsx`

Used for the guided setup flow:

1. setup
2. players
3. constraints
4. generate

## Persistence model

### Previous model

The previous backend was Google Apps Script plus Google Sheets.

That model stored JSON blobs per row and computed list/stat views by scanning
the full dataset.

### Current runtime direction

The app now targets the `bm` schema as the runtime backend.

Current persistence strategy is:

- aggregate-root oriented
- compatibility-snapshot preserving
- relationally normalized for session internals and player stats

This keeps product behavior stable while reducing migration risk.

## Design principle

The intended architecture is:

- keep product behavior in the frontend
- keep storage concerns behind the query layer
- keep pure domain logic in generator and utility modules
- avoid making `MDEF` shape the internal schema of `badminton-match`
- treat `bm` as the primary production-target schema
