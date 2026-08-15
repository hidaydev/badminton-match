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

### Domain types

Shared domain types are in:

- `src/types/index.ts`

This module defines `Player`, `FixMatch`, `ScheduleSlot`, `GameScore`, `CourtTime`, `SessionConfig`, `Gender`, `Tier`, and `PLAYERS_PER_GAME`. Zero dependencies — imported by all layers.

### Time utilities

Pure time/scheduling functions are in:

- `src/utils/time.ts`

This module defines `timeToMinutes`, `minutesToTime`, `computeTimeSlots`, `courtsAtTime`, `timeToSlotIndex`, `derivedFromCourtTimes`. Imports only from `types/`.

### Local app state: Zustand

Primary local state is in:

- `src/store/index.ts`

This store imports types from `types/` and time utilities from `utils/time/`. It owns:

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

Tournament state is managed through React Query hooks rather than a local store.
The previous `store/tournament.ts` was removed as dead code — TournamentPage uses
the query layer directly.

## Query layer

Remote read/write access is wrapped in:

- `src/queries/endpoints.ts` — raw REST fetch functions (retry method-aware) terhadap `majadu-api`
- `src/queries/retry.ts` — retry policy murni (method-aware, testable)
- `src/queries/sessions.ts` — session query hooks
- `src/queries/players.ts` — player query hooks
- `src/queries/tournament.ts` — tournament query hooks
- `src/queries/types.ts` — CloudSnapshot, SessionMeta, PlayerSummary, PlayerStats types
- `src/queries/errors.ts` — user-friendly error message mapper

### Session query hooks

| Hook | Purpose |
|------|---------|
| `useListSessions` | List all published sessions |
| `useGetSession` | Fetch single session snapshot |
| `usePublishSession` | Publish/update session to cloud |
| `useTogglePlayed` | Toggle game played status |
| `useSetScore` | Set game score |
| `useSwapPlayers` | Swap two players between games |
| `useSwapTeams` | Swap two teams between games |
| `useSwapSlots` | Swap two game slots |
| `useSetAbsent` | Mark/unmark players as absent |
| `useReplacePlayer` | Replace player name in session |
| `useDeleteSession` | Delete session (admin) |
| `useLockSession` | Lock session (prevent edits) |
| `useChangePlayer` | Change one player in a specific game |
| `useFetchSession` | Fetch session for imperative use |

All mutations follow the optimistic update pattern: `onMutate` → `mutationFn` → `onSuccess`/`onError` with version mismatch retry. Error handling is rollback-first — `onError` rolls back the optimistic update before any refetch. `onSuccess` uses `fetchQuery` to refetch from the server rather than `setQueryData(server_response)`, preventing race conditions where a subsequent mutation's optimistic update gets overwritten by a stale response.

Most session mutations use the `useOptimisticSessionMutation` factory (`queries/useOptimisticMutation.ts`) which encapsulates the shared onMutate/onError/onSuccess boilerplate. Each hook only needs to provide an `optimisticUpdate` function.

The pages and components should depend on these query hooks rather than
embedding storage details directly.

GeneratePage debounces cloud publishes (300 ms trailing, 1s max delay) to coalesce rapid local mutations. The pending publish is flushed on component unmount as a fire-and-forget call.

## Domain logic

### Session generator

Main file:

- `src/generator/index.ts`

This is the core scheduling engine. It imports domain types from `types/` and `timeToSlotIndex` from `utils/time/` — it has no dependency on the store.

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

### Shared config

- `src/config/tiers.ts` — tier labels, colors, badge colors, and tier names shared across GeneratePage, PlayersPage, and ConstraintsPage
- `src/config/generator.ts` — named constants for the generator algorithm (scoring weights, retry counts, candidate limits)
- `src/config/canvas.ts` — canvas dimensions, font families, header/logo sizes

### Operational mutations

Utility files:

- `src/utils/time.ts` — time/slot computation (`timeToMinutes`, `minutesToTime`, `computeTimeSlots`, `courtsAtTime`, `timeToSlotIndex`, `derivedFromCourtTimes`)
- `src/utils/counter.ts` — shared symmetric co-occurrence counter (`bumpCoOccurrence`)
- `src/utils/array.ts` — shared array utilities (`shuffle`)
- `src/utils/quality.ts` — schedule quality analysis (`computeQuality`, `qualityScore`, `isGoodQuality`)
- `src/utils/reconcilePlayers.ts` — player list rebuild from schedule (`rebuildPlayersFromSchedule`)
- `src/utils/tally.ts` — shared match tallying logic (`initTallyRow`, `tallyMatch`, `computeDiff`, `standardStandingSort`)
- `src/utils/share.ts` — iOS share / fallback download (`canvasToBlob`, `shareOrDownload`)
- `src/utils/overlays.ts` — overlay image loading utility (`loadOverlayImages`)
- `src/utils/swap.ts` — player swaps, team swaps, change player logic, conflict detection
- `src/utils/slotSwap.ts` — game slot swaps
- `src/utils/standings.ts` — standings computation for live session views
- `src/utils/sessionSnapshot.ts` — snapshot mutation helpers (toggle played, set score, swap players/teams/slots, set absent, replace player name, change player)
- `src/utils/playerStats.ts` — `computePlayerStats()` for play/sit/partner/opponent counts
- `src/utils/ordinal.ts` — `ordinal()` helper (1st, 2nd, 3rd, etc.)

These support:

- player swaps
- slot swaps
- standings computation for live session views
- player stats computation for shared session and generate page

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

### SummaryModal sub-components

The SummaryModal is the operations console for live session management. It has been
decomposed into focused sub-components:

- `src/components/SummaryModal.tsx` — main modal
- `src/components/summary/ConfirmBars.tsx` — fixed bottom confirm bars (swap, absent, change player, lock, share)
- `src/components/summary/ActionsMenu.tsx` — actions dropdown with mode entry buttons
- `src/components/summary/PlayerStatsPanel.tsx` — player stats display with standalone/generate branches
- `src/components/summary/SlotGameCard.tsx` — individual game card in schedule grid
- `src/components/summary/PlayerMatchDetailSheet.tsx` — player match detail bottom sheet
- `src/components/generate/ScheduleComponents.tsx` — QualityBanner, PlayerChip, TierBalance, ScheduleView

## Persistence model

### Previous models

1. Google Apps Script + Google Sheets (era 1) — JSON blobs per row, list/stats
   dihitung dengan scanning dataset penuh.
2. Supabase/PostgREST schema `bm` (era 2) — RPC functions SECURITY DEFINER.

### Current runtime (era 3, 2026-08)

Backend **Go (`majadu-api`)** menghubungkan frontend ke Postgres VPS langsung
(pgx, tanpa PostgREST):

- write-path session/tournament: transaksi + advisory lock + version concurrency
- read-path: rebuild snapshot langsung di Go
- schema `bm` (prod) / `bm_dev` (dev), migrasi di `majadu-api/migrations/`
- semua logika validasi/lock/resolve ada di Go — sisa fungsi SQL hanya
  `normalize_player_name` (CHECK constraint) + utilitas

Ini menjaga kontrak snapshot tetap stabil sambil memindahkan logika backend ke
satu bahasa (Go) yang teruji.

## Design principle

- keep product behavior in the frontend
- keep storage concerns behind the query layer
- keep pure domain logic in generator and utility modules
- avoid making `MDEF` shape the internal schema of `badminton-match`
- treat `bm`/`bm_dev` as the runtime schema, diakses via `majadu-api`

## Clean Architecture (post-audit)

After the clean code audit (Phase 1–12), the codebase follows a strict dependency flow:

```
src/
├── types/              # Domain types (zero deps) — Player, FixMatch, ScheduleSlot, etc.
├── config/             # Named constants — generator weights, canvas dims, tier config, tokens
├── generator/          # Pure scheduling engine — zero imports from store/ or queries/
├── utils/              # Pure utilities — time, quality, standings, swap, canvas, stats
├── domain/ports/       # Repository interfaces (prepared for DI)
├── queries/            # React Query hooks + REST client (majadu-api)
│   ├── endpoints.ts    # Raw REST fetch functions (retry method-aware)
│   ├── retry.ts        # Retry policy murni (testable)
│   ├── sessions.ts     # Session query hooks (14 hooks)
│   ├── players.ts      # Player query hooks
│   ├── tournament.ts   # Tournament query hooks
│   ├── types.ts        # CloudSnapshot, SessionMeta, PlayerSummary types
│   ├── errors.ts       # User-friendly error mapper + isVersionMismatch helper
│   └── useOptimisticMutation.ts  # Factory hook for optimistic mutations
├── store/              # Zustand slices (session, players, schedule, game, ui)
├── hooks/              # Custom React hooks (useDebouncedPublish, etc.)
├── components/         # UI components
│   ├── summary/        # SummaryModal sub-components (ConfirmBars, ActionsMenu, etc.)
│   ├── tournament/     # Tournament tab components
│   └── generate/       # Schedule view components (QualityBanner, PlayerChip, etc.)
├── pages/              # Route pages
└── index.css           # Tailwind v4 @theme tokens
```

### Dependency rules

| Layer | Can import from | Cannot import from |
|-------|----------------|-------------------|
| `types/` | nothing | everything else |
| `config/` | `types/` | `store/`, `queries/`, `pages/` |
| `generator/` | `types/`, `config/`, `utils/time` | `store/`, `queries/`, `pages/` |
| `utils/` | `types/`, `config/` | `store/`, `queries/`, `pages/` |
| `queries/` | `types/`, `config/`, `utils/`, `domain/ports` | `store/`, `pages/` |
| `store/` | `types/`, `config/`, `utils/` | `queries/`, `pages/` |
| `components/` | everything except `pages/` | `pages/` |
| `pages/` | everything | — |

### Key patterns

- **Optimistic mutation factory** — `useOptimisticSessionMutation` eliminates boilerplate across 7+ mutation hooks. Each hook only provides an `optimisticUpdate` function.
- **Snapshot-based persistence** — entire session state serialized as `CloudSnapshot` JSON. Publish is full replace with version concurrency.
- **Debounced cloud publishing** — `useDebouncedPublish` batches rapid changes (300ms trailing, 1s max delay) with flush on unmount.
- **Branded types** — `PlayerId`, `TimeString`, `GameKey` provide type safety without runtime overhead.
- **Zustand sliced composition** — 5 slices with shared `SetState` type, persisted to localStorage with version migration.
- **Computed selectors** — `selectSlotsPerCourt`, `selectTotalGames` derived from config, not stored.
- **5-phase generator** — pinned placement → merge pairable → spread → flexible → greedy fill. Scoring weights injectable via config.
