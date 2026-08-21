# Product Overview

## Purpose

`badminton-match` (Majadu) is a badminton operations app. It is optimized for real
session management, rating/leaderboard tracking, and tournament management.

The app is designed to answer these operational questions:

- How many courts and players do we have today?
- How do we create a fair doubles schedule?
- How do we preserve requested pairings or rivalries?
- How do we run the session live and keep everyone aligned?
- How do we present session outcomes and tournament results cleanly?
- Who are the top players and how are they trending?

## Core product areas

### 1. Session setup

Users configure:

- session title
- date
- number of courts
- session start time
- per-court availability
- game duration
- target player count

### 2. Player management

Users can:

- add players one by one
- bulk import players from pasted text
- edit names inline
- assign gender (stored canonically in `players` table)
- assign skill tier (8-tier: D, D+, C, C+, B, B+, A, A+)
- tier is "first-set sticky" — canonical tier from backend, read-only for registered players

### 3. Constraints

Users can define fixed matches such as:

- specific partners together
- specific opponents against each other
- partial fixed matches with open slots

### 4. Schedule generation

The app generates a doubles schedule that tries to balance:

- total play count
- repeated partners
- repeated opponents
- team strength by tier
- back-to-back fatigue

### 5. Shared live session

Once a session is published:

- a shared URL becomes the live source
- scores and played flags can be updated
- players can be swapped
- slots can be swapped
- teams can be swapped
- one player in a specific game can be changed
- absences can be recorded
- player stats (play count, sit count, partners, opponents) are visible
- session can be locked to prevent further changes
- locked sessions reject all mutations at the server level
- auto-lock: sessions lock automatically when all scores entered or date passed

### 6. Ratings & Leaderboard

The app tracks player ratings using a **Glicko-1-lite** engine:

- 8-tier ClassBands (D: 1000–1199, ..., A+: 2100+)
- Season system with configurable start date and decay
- Leaderboard with server-side pagination
- Player detail: stat cards, sparkline trend, recent matches (paginated), career stats
- Auto-ingest on session lock (backend ticker every 30 min)

### 7. Tournament

The tournament module supports two formats:

**Classic:**
- 16 fixed pairs → 4 groups → round-robin → knockout bracket
- Bracket visualization with connector lines
- Group standings with head-to-head

**Team:**
- 36 players (6 classes × 6 teams) with manual team assignment
- 9 group matches (round-robin) + 1 final
- Editable team names in standings
- Team member display under each team
- Champion banner with trophy decoration
- Instagram post export with dark gradient frame

### 8. Social export

The app can render session and tournament visuals for sharing:

- Instagram-style post assets (1080×1350 posts, 1080×1920 stories)
- standings cards
- bracket cover and result assets
- team tournament standings post (dark gradient frame)

### 9. Admin

5 separate admin pages for managing the system:

- **Sessions** — list, lock, delete sessions
- **Players** — list, rename, delete players, set tier
- **Ratings** — ingest, revert, rebuild ratings
- **Tournaments** — list, delete tournaments
- **Seasons** — manage rating seasons

## Architecture

- **Frontend**: React 19, Vite, Tailwind v4, TypeScript (deployed on Vercel)
- **Backend**: Go (`majadu-api` repo, deployed on VPS via podman)
- **Database**: PostgreSQL on VPS (`bm_dev` schema)
- **Rating engine**: Glicko-1-lite with 8-tier ClassBands
