# Features And Routes

## Top-level routes

Defined in:

- `src/App.tsx`

### Home shell routes

- `/`
  - home page (menu APP + section ADMIN saat login admin)
- `/sessions`
  - published session list
- `/rankings`
  - leaderboard poin 12 minggu (8-tier) — pemain history digabung di detail (Career)
- `/rankings/:playerId`
  - detail poin + career stats (bekas Player History)
- `/ratings` · `/ratings/:playerId`
  - alamat lama, hanya redirect ke `/rankings` / `/rankings/:playerId` (`App.tsx:112-114`)
- `/tournaments`
  - tournament list (classic + team)
- `/tournaments/new` · `/tournaments/new/:format`
  - wizard tournament
- `/tournaments/:id`
  - detail tournament (branch format)
- `/admin`
  - redirect ke `/admin/sessions`
- `/admin/sessions`
  - unlock & delete sesi
- `/admin/players`
  - tambah/rename/tier/merge/hapus pemain
- `/admin/ratings`
  - ingest, revert, rebuild rating (papan poin)
- `/admin/tournaments`
  - hapus turnamen
- `/instagram-post`
  - session and tournament media export

### Standalone route

- `/scoreboard`
  - fullscreen/mobile-friendly scoring screen
- `/dev/achievement-badges`
  - preview semua badge achievement (dev)
- `/dev/match-result-preview`
  - preview kartu hasil pertandingan (dev)
- `/dev/session-preview`
  - preview halaman sesi (dev)

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
- server rejects setiap mutasi selama status bukan `draft` (write-path Go)
- delete session is also blocked for locked sessions
- unlock tersedia di admin UI — `AdminSessionsPage`, `POST /sessions/{id}/unlock`
- unlock bumps the session version
- auto-lock triggers on save when all scores are entered (save-path, no ticker)

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

## Player history flow (diserap ke Rankings — 2026-08-19)

Files:

- `src/pages/RatingPlayerPage.tsx` (section Career)
- `src/components/ratings/CareerStats.tsx`

Capabilities:

- recent matches show "with teammate · vs opponent" format (BE fetches teammates/opponents via correlated subqueries on rating_deltas; `COALESCE(array_agg, '{}')` sehingga selalu array, tidak `null` saat partner absent/skipped — fix 2026-09-07)
- career stats (W/L, points, sessions, top partners/opponents, tournament)
  dirender di `/rankings/:playerId` — satu halaman, tanpa cross-link nested.
- Route `/player-history*` dan halaman terpisah DIHAPUS (keputusan 2026-08-19).

## Achievements

Files:

- `src/config/achievements.ts` (definisi & ambang)
- `src/components/ratings/AchievementBadge.tsx`
- `src/components/ratings/AchievementDetailModal.tsx`
- `src/pages/AchievementBadgesPreviewPage.tsx` (route dev `/dev/achievement-badges`)

Badge koleksi per pemain, dihitung backend dari riwayat pertandingan & tournament
(`apps/api/internal/domain/achievements.go`, tabel `player_achievements` — migrasi `000016`).
Ditampilkan di halaman detail ranking `/rankings/:playerId`.

## Tournament flow

### Classic Tournament

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

### Team Tournament

Files:

- `src/pages/TeamTournamentPage.tsx`
- `src/pages/NewTournamentWizard.tsx` (TeamWizard)
- `src/utils/teamTournament.ts`
- `src/utils/teamTournamentPost.ts`

Capabilities:

- 36 players (6 classes × 6 teams) with manual team assignment in wizard
- 9 group matches (round-robin) + 1 final
- Editable team names in standings
- Team member display under each team name
- Champion banner with trophy decoration in final tab
- Crown icon for rank 1 in standings
- Instagram post export with dark gradient frame

## Social export flow

Files:

- `src/pages/InstagramPostPage.tsx`
- `src/utils/canvasPost.ts`
- `src/utils/teamTournamentPost.ts`

Capabilities:

- compose branded images with uploaded or selected photos
- render standings and tournament outputs to canvas
- export share-ready assets
- team tournament standings post (dark gradient frame)

## API endpoints (backend `apps/api`)

Sumber: `apps/api/cmd/server/main.go:184-259` — 48 rute terdaftar. Ini **API**, bukan
halaman web: papan peringkat dibaca dari `GET /rankings`, sedangkan halaman web-nya
`/rankings` (`src/App.tsx:110-111`). Di prod semua path ber-prefix base path `/majadu`.

| Method | Path | Auth |
|---|---|---|
| GET | `/healthz` | publik |
| GET | `/readyz` | publik |
| GET | `/version` | publik |
| GET | `/admin/verify` | admin |
| GET | `/metrics` | publik |
| GET | `/sessions` | publik |
| POST | `/sessions` | publik |
| GET | `/sessions/{id}` | publik |
| GET | `/sessions/{id}/watch` | publik (SSE) |
| PUT | `/sessions/{id}` | publik |
| PATCH | `/sessions/{id}` | publik |
| DELETE | `/sessions/{id}` | admin |
| POST | `/sessions/{id}/lock` | admin |
| GET | `/sessions/{id}/games/{gameKey}` | publik |
| PATCH | `/sessions/{id}/games/{gameKey}` | publik |
| PATCH | `/sessions/{id}/games/{gameKey}/skip` | publik |
| PATCH | `/sessions/{id}/absent` | publik |
| POST | `/sessions/{id}/swap` | publik |
| GET | `/sessions/{id}/events` | publik |
| POST | `/sessions/{id}/unlock` | admin |
| POST | `/sessions/{id}/delete` | admin |
| GET | `/players` | publik |
| POST | `/players` | publik |
| GET | `/players/{name}/stats` | publik |
| PATCH | `/players/{playerId}/tier` | admin |
| PATCH | `/players/{playerId}/name` | admin |
| DELETE | `/players/{playerId}` | admin |
| POST | `/players/merge` | admin |
| GET | `/tournaments` | publik |
| POST | `/tournaments` | publik |
| GET | `/tournaments/{id}` | publik |
| PUT | `/tournaments/{id}` | publik |
| PATCH | `/tournaments/{id}` | publik |
| POST | `/tournaments/{id}/delete` | admin |
| GET | `/rankings` | publik |
| GET | `/rankings/players/{playerId}` | publik |
| GET | `/ratings/players/{playerId}` | publik |
| GET | `/ratings/players/{playerId}/achievements` | publik |
| GET | `/ratings/sources` | publik |
| POST | `/ratings/ingest-session` | admin |
| POST | `/ratings/ingest-tournament` | admin |
| POST | `/ratings/revert-session` | admin |
| POST | `/ratings/revert-tournament` | admin |
| POST | `/ratings/sources/{sourceId}/finalize` | admin |
| POST | `/ratings/rebuild-all` | admin |
| POST | `/ratings/replay-all` | admin |
| POST | `/ratings/replay-source` | admin |
| POST | `/ratings/achievements/backfill` | admin |
