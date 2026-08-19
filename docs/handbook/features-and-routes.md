# Features And Routes

## Top-level routes

Defined in:

- `src/App.tsx`

### Home shell routes

- `/`
  - home page (menu APP + section ADMIN saat login admin)
- `/sessions`
  - published session list
- `/ratings`
  - rating leaderboard (8-tier) — pemain history digabung di detail (Career)
- `/ratings/:playerId`
  - detail rating + career stats (bekas Player History)
- `/tournaments`
  - tournament list (classic + team)
- `/tournaments/new` · `/tournaments/new/:format`
  - wizard tournament
- `/tournaments/:id`
  - detail tournament (branch format)
- `/admin`
  - halaman operasi admin (bisa di-autofocus via `/admin?section=X`)
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
- change one player in a specific game
- mark absences
- rename session-local players
- delete session
- lock session (prevents all mutations)

The summary modal acts as the operations console for live session management.

### Lock behavior

When a session is locked:

- all interactive elements are disabled (checkboxes, scores, actions)
- server rejects any mutation via `publish_session` (any non-draft status blocks writes)
- delete session is also blocked for locked sessions
- unlock is admin-only via `bm.unlock_session` RPC (not in UI)
- unlock bumps the session version

### Player stats in shared view

The schedule tab in SummaryModal shows per-player stats:

- play count (how many times each player plays)
- sit count (how many times each player sits out)
- unique partners
- unique opponents

In standalone mode (host view), the stats panel uses a 2-column grid layout without
target/ideal plays. Absent players are greyed out with an absent badge and sorted
to the bottom of the list. All players from the schedule are included (not just
those in playerMap), supporting the Change Player flow.

### Change player

Change Player allows the host to swap one player in a specific game slot.
Restricted to published sessions only (not available during schedule generation).

- **Cross-slot conflict detection** — prevents assigning the same player to
  multiple games in the same time slot across different courts
- **Confirmation bar** — changes are staged and shown in a bottom confirm bar
  (consistent with swap/absent patterns) before being committed
- **Back-to-back warning** — the confirm bar shows a warning when the replacement
  player would play back-to-back games

## Player history flow (diserap ke Ratings — 2026-08-19)

Files:

- `src/pages/RatingPlayerPage.tsx` (section Career)
- `src/components/ratings/CareerStats.tsx`

Capabilities:

- career stats (W/L, points, sessions, top partners/opponents, tournament)
  dirender di `/ratings/:playerId` — satu halaman, tanpa cross-link nested.
- Route `/player-history*` dan halaman terpisah DIHAPUS (keputusan 2026-08-19).

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
