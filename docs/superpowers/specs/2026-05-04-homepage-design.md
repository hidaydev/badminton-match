# Homepage & Navigation Redesign

**Date:** 2026-05-04  
**Branch:** feat/homepage  
**Status:** Approved

## Overview

Add a homepage at `/` with a menu for the four main areas of the app. Move the existing session creation wizard to `/session/*`. Add a session list and player history powered by new Google Apps Script endpoints.

---

## 1. Routing & Layout

Two layouts replace the single current `Layout`:

- **`HomeLayout`** — header with logo + title only, no stepper. Used by all non-wizard pages.
- **`SessionLayout`** — existing layout with stepper. Used by the session creation wizard.

### Route Map

| Path | Component | Layout |
|---|---|---|
| `/` | `HomePage` | HomeLayout |
| `/session/new` | `SetupPage` | SessionLayout |
| `/session/players` | `PlayersPage` | SessionLayout |
| `/session/constraints` | `ConstraintsPage` | SessionLayout |
| `/session/generate` | `GeneratePage` | SessionLayout |
| `/sessions` | `SessionListPage` | HomeLayout |
| `/player-history` | `PlayerHistoryPage` | HomeLayout |
| `/player-history/:name` | `PlayerDetailPage` | HomeLayout |
| `/tournament` | `TournamentPage` | HomeLayout |
| `/view` | `SharedViewPage` | SessionLayout |
| `/s/:sessionId` | `SharedSessionPage` | standalone (unchanged) |

`RequireSession` redirects to `/session/new` (was `/`).  
`RequirePlayers` redirects to `/session/players` (was `/players`).

The stepper in `SessionLayout` updates its `to` paths to the new `/session/*` routes.

---

## 2. Homepage (`/`)

Landing page with app title, tagline, and 4 menu cards in a 2×2 grid. Dark slate theme consistent with the rest of the app.

| Card | Icon | Route |
|---|---|---|
| Create Session | 🏸 | `/session/new` |
| Sessions | 📋 | `/sessions` |
| Player History | 👤 | `/player-history` |
| Tournament | 🏆 | `/tournament` |

Tournament card shows a "Coming Soon" badge. All other cards navigate immediately.

---

## 3. Session List (`/sessions`)

Fetches all sessions via `?action=list`. Sessions sorted by date descending.

Each card shows: title, date, player count, total games.  
Tapping a card navigates to `/s/:sessionId` (existing shared view).

Loading and error states shown inline.

---

## 4. Player History

### `/player-history`
Fetches all players via `?action=players`. Deduplication is case-insensitive by name.  
Shows a list: name, gender, tier. Tap to view detail.

### `/player-history/:name`
URL param is the player name (URL-encoded). Lookup is case-insensitive.  
Fetches via `?action=playerStats&name=<name>`.

Displays:
- Total games played, wins, losses, win rate
- Sessions attended (count + list with date + title)
- Top partners (name + count)
- Top opponents (name + count)

Loading and error states shown inline.

---

## 5. Apps Script Changes (`apps-script/Code.gs`)

Three new `action` values added to `doGet`. Existing `?id=` and `POST` behavior unchanged.

### `?action=list`
Scans all rows, parses each session's `data` JSON.  
Returns: `{ ok: true, data: [{ id, title, date, playerCount, totalGames }] }`

### `?action=players`
Scans all sessions, collects all player names.  
Deduplication is case-insensitive; uses most recent session's values (gender, tier) for each name.  
Returns: `{ ok: true, data: [{ name, gender, tier }] }`

### `?action=playerStats&name=<name>`
Scans all sessions, matches player by name (case-insensitive).  
Aggregates across all matched games.  
Returns:
```json
{
  "ok": true,
  "data": {
    "name": "Ali",
    "gamesPlayed": 12,
    "wins": 7,
    "losses": 5,
    "pointsFor": 134,
    "pointsAgainst": 110,
    "sessions": [{ "id": "...", "date": "2026-04-01", "title": "Tuesday Session" }],
    "topPartners": [{ "name": "Bob", "count": 5 }],
    "topOpponents": [{ "name": "Carol", "count": 4 }]
  }
}
```

---

## 6. `cloudSync.ts` Changes

Three new functions added. Existing functions unchanged.

```ts
interface SessionMeta {
  id: string
  title: string
  date: string
  playerCount: number
  totalGames: number
}

interface PlayerSummary {
  name: string
  gender: 'M' | 'F'
  tier: 1 | 2 | 3 | 4
}

interface PlayerStats {
  name: string
  gamesPlayed: number
  wins: number
  losses: number
  pointsFor: number
  pointsAgainst: number
  sessions: { id: string; date: string; title: string }[]
  topPartners: { name: string; count: number }[]
  topOpponents: { name: string; count: number }[]
}

listSessions(): Promise<SessionMeta[]>
listPlayers(): Promise<PlayerSummary[]>
getPlayerStats(name: string): Promise<PlayerStats>
```

---

## 7. New Files

- `src/components/HomeLayout.tsx`
- `src/pages/HomePage.tsx`
- `src/pages/SessionListPage.tsx`
- `src/pages/PlayerHistoryPage.tsx`
- `src/pages/PlayerDetailPage.tsx`
- `src/pages/TournamentPage.tsx`

## 8. Modified Files

- `src/App.tsx` — new routes, two layouts
- `src/components/Layout.tsx` → renamed `SessionLayout.tsx`, stepper paths updated
- `src/utils/cloudSync.ts` — 3 new functions + new interfaces
- `apps-script/Code.gs` — 3 new action handlers in `doGet`
