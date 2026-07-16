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

Tournament state is managed through React Query hooks rather than a local store.
The previous `store/tournament.ts` was removed as dead code — TournamentPage uses
the query layer directly.

## Query layer

Remote read/write access is wrapped in:

- `src/queries/endpoints.ts` — raw Supabase RPC fetch functions
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

All mutations follow the optimistic update pattern: `onMutate` → `mutationFn` → `onSuccess`/`onError` with version mismatch retry. `onSuccess` uses `fetchQuery` to refetch from the server rather than `setQueryData(server_response)`, preventing race conditions where a subsequent mutation's optimistic update gets overwritten by a stale response.

The pages and components should depend on these query hooks rather than
embedding storage details directly.

GeneratePage debounces cloud publishes (300 ms trailing) to coalesce rapid local mutations. The pending publish is flushed on component unmount as a fire-and-forget call.

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

### Shared config

- `src/config/tiers.ts` — tier labels, colors, badge colors, and tier names shared across GeneratePage, PlayersPage, and ConstraintsPage

### Operational mutations

Utility files:

- `src/utils/swap.ts` — player swaps, change player logic
- `src/utils/slotSwap.ts` — game slot swaps
- `src/utils/standings.ts` — standings computation for live session views
- `src/utils/sessionSnapshot.ts` — snapshot mutation helpers (change player, rename)
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

- `src/components/SummaryModal.tsx` — main modal (1277 lines)
- `src/components/ConfirmBars.tsx` — 5 fixed bottom confirm bars (swap, absent, change player, lock, share)
- `src/components/ActionsMenu.tsx` — actions dropdown with mode entry buttons
- `src/components/PlayerStatsPanel.tsx` — player stats display with standalone/generate branches

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
