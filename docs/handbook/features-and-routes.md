# Features And Routes

## Top-level routes

Defined in:

- `src/App.tsx`

### Home shell routes

- `/`
  - home page
- `/sessions`
  - published session list
- `/player-history`
  - player index
- `/player-history/:name`
  - player detail stats
- `/tournament`
  - tournament module
- `/instagram-post`
  - session and tournament media export

### Standalone route

- `/scoreboard`
  - fullscreen/mobile-friendly scoring screen

### Guided session flow

- `/session/new`
  - setup
- `/session/players`
  - player entry
- `/session/constraints`
  - fixed matches
- `/session/generate`
  - schedule generation and publish

### Shared/public routes

- `/view`
  - hash-based local shared-view mode
- `/s/:sessionId`
  - published shared session page

## Session flow

### Setup page

File:

- `src/pages/SetupPage.tsx`

Key capabilities:

- identity fields
- court count and per-court hours
- total game preview
- lock/start session

### Players page

File:

- `src/pages/PlayersPage.tsx`

Key capabilities:

- add/edit/remove players
- bulk import from pasted text
- tier grouping
- completion gating to next step

### Constraints page

File:

- `src/pages/ConstraintsPage.tsx`

Key capabilities:

- build fixed matches
- validate impossible or overloaded constraints
- prevent continuing with invalid constraint set
- pinned matches: assign time and court to specific matches
- flexible matches: generator decides placement

### Generate page

File:

- `src/pages/GeneratePage.tsx`

Key capabilities:

- run generator
- display quality summary
- retry generation until a better result is found
- publish/share session
- open summary modal

## Shared session flow

File:

- `src/pages/SharedSessionPage.tsx`

Capabilities:

- load cloud session snapshot
- mutate scores and played flags
- swap players
- swap slots
- swap teams
- mark absences
- rename session-local players
- delete session
- lock session (prevents all mutations)

The summary modal acts as the operations console for live session management.

### Lock behavior

When a session is locked:

- all interactive elements are disabled (checkboxes, scores, actions)
- server rejects any mutation via `publish_session`
- unlock is admin-only via `bm.unlock_session` RPC (not in UI)

### Player stats in shared view

The schedule tab in SummaryModal shows per-player stats:

- play count (how many times each player plays)
- sit count (how many times each player sits out)
- unique partners
- unique opponents

## Player history flow

Files:

- `src/pages/PlayerHistoryPage.tsx`
- `src/pages/PlayerDetailPage.tsx`

Capabilities:

- list known players
- fetch aggregate player stats
- display sessions, partners, and opponents

## Tournament flow

Files:

- `src/pages/TournamentPage.tsx`
- `src/components/tournament/*`

Capabilities:

- assign pairs into numbered group slots
- confirm groups
- score group matches
- compute standings
- propagate quarterfinal/semifinal/final bracket
- export group summaries and bracket media

## Social export flow

Files:

- `src/pages/InstagramPostPage.tsx`
- `src/utils/canvasPost.ts`

Capabilities:

- compose branded images with uploaded or selected photos
- render standings and tournament outputs to canvas
- export share-ready assets
