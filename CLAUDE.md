# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

Run web commands from the monorepo root (root `package.json` proxies to `apps/web`), or `cd apps/web`:

```bash
npm run dev            # Start dev server (Vite HMR) — root proxy ke apps/web
npm run build:web      # Type-check then build for production (apps/web)
npm run check:web      # Web: types + lint + tailwind + regression tests
npm run check:api      # API: go vet + fmt + test (apps/api)
# make equivalents: make dev · make dev-api · make build-web · make check-web · make check-api
```

Regression tests exist via `node:test` (pure logic — retry policy, generator quality, snapshot helpers, tournament bracket) in `apps/web/scripts/tests/`:

```bash
cd apps/web
npm run check              # Types + lint + tailwind + regression tests
npm run check:regression   # Regression tests only (node:test)
```

Backend lives in the same monorepo at `apps/api` (`go test ./...` — unit + handler + integration test env-guarded via `MAJADU_TEST_DATABASE_URL`). See `apps/api/README.md`.

## Architecture

This is a mobile-first React PWA (React 19, Vite, Tailwind v4, TypeScript) in `apps/web` that generates optimised badminton match schedules for recreational sessions. It has grown to also include tournament management, session history, ratings/leaderboard, and admin tools. Backend is Go (`apps/api`, `net/http` + pgx) backed by Postgres on a VPS.

### Core Session Flow

**User flow (4 steps, enforced by route guards in [App.tsx](apps/web/src/App.tsx)):**
1. **Setup** (`/session/new`) — configure courts, slot duration, court times, player count, tier count (8-tier: D, D+, C, C+, B, B+, A, A+). Locks the session.
2. **Players** (`/session/players`) — add/edit players with name, gender, and tier (1–8). Tier picker is read-only for registered players (canonical tier from backend).
3. **Constraints** (`/session/constraints`) — define "fix matches": pre-assigned pairings (fully or partially specified) that must appear in the schedule.
4. **Generate** (`/session/generate`) — run the scheduler, view the schedule, retry until quality is good.

**Routing:** `RequireSession` redirects to `/session/new` if the session isn't locked; `RequirePlayers` additionally checks that the exact `playerCount` players have been entered before allowing access to `/session/constraints` or `/session/generate`.

**Home page** shows 6 cards: Sessions, Ratings, Scoreboard, Tournament, IG Post, Admin. Admin section (5 cards: Sessions, Players, Ratings, Tournaments, Seasons) appears after login.

### State Management

One Zustand store, persisted to `localStorage`:

- **Main store** ([apps/web/src/store/index.ts](apps/web/src/store/index.ts)) — key `badminton-store`, `version: 14`. Holds session config, players, fix matches, schedule, played games, game scores, absent players, and `cloudSessionId`. Mutating any player, fix match, or session field resets `schedule` and `lastResult` to `null`.

Migration resets to defaults on any version mismatch. The tournament store was removed — TournamentPage uses React Query directly.

### Generator

[apps/web/src/generator/index.ts](apps/web/src/generator/index.ts) is pure TypeScript with no external dependencies. Key algorithm:
- Scores a game by `partnerRepeat × 3 + opponentRepeat + tierDiff × 2` — lower is better.
- Two "A-side-only" fix matches can be *merged* into a single game (one pair becomes Team A, the other Team B) to pack the schedule more efficiently.
- Fix matches are placed first (most specified first), then remaining slots are filled greedily by choosing players with the lowest projected play count, preferring those who sat out recently.
- `bestGrouping` runs 40 random shuffles and picks the grouping with the lowest aggregate score.
- `courtOffsets` handle courts that start at different times (e.g. Court B opens an hour later than Court A).

### Pages

- **GeneratePage** ([apps/web/src/pages/GeneratePage.tsx](apps/web/src/pages/GeneratePage.tsx)) — `QualityBanner` grades the schedule; "Retry until good" runs up to 30 generations; `SummaryModal` is a full-screen overlay with a checklist view (tap to mark games as played, support for absent players). Debounces cloud publishes (300 ms trailing, 1s max delay) and flushes on unmount.
- **RatingsPage** ([apps/web/src/pages/RatingsPage.tsx](apps/web/src/pages/RatingsPage.tsx)) — leaderboard with server-side pagination (100 per page), "Load more" button. Shows tier badge, rating, trend, games count. Peak rating removed from list (shown in player detail).
- **RatingPlayerPage** ([apps/web/src/pages/RatingPlayerPage.tsx](apps/web/src/pages/RatingPlayerPage.tsx)) — per-player rating detail: stat cards (peak, games, W-L, tier), sparkline trend, recent matches (paginated, 5/page, shows "with teammate · vs opponent" format), career stats from `CareerStats.tsx`.
- **TournamentPage** ([apps/web/src/pages/TournamentPage.tsx](apps/web/src/pages/TournamentPage.tsx)) — tabbed UI for classic tournament: **Groups**, **Bracket**, **Standings**.
- **TeamTournamentPage** ([apps/web/src/pages/TeamTournamentPage.tsx](apps/web/src/pages/TeamTournamentPage.tsx)) — tabbed UI for team tournament: **Standings** (editable team names, member list, crown for champion), **Schedule** (score entry per partai), **Final** (champion banner). Includes Instagram post export.
- **SessionListPage** ([apps/web/src/pages/SessionListPage.tsx](apps/web/src/pages/SessionListPage.tsx)) — browse past cloud-synced sessions with date filter.
- **SharedSessionPage** ([apps/web/src/pages/SharedSessionPage.tsx](apps/web/src/pages/SharedSessionPage.tsx)) — view/manage a cloud-synced shared session (`/s/:sessionId`).
- **InstagramPostPage** ([apps/web/src/pages/InstagramPostPage.tsx](apps/web/src/pages/InstagramPostPage.tsx)) — HTML5 Canvas editor for creating branded Instagram posts (1080×1350) and stories (1080×1920).
- **NewTournamentWizard** ([apps/web/src/pages/NewTournamentWizard.tsx](apps/web/src/pages/NewTournamentWizard.tsx)) — 3-step wizard for creating tournaments. Classic: 16 pairs → 4 groups. Team: 36 players (6 classes × 6 teams) with manual team assignment.

### Admin Pages (`apps/web/src/pages/admin/`)

5 separate admin pages, each with `AdminPageShell` layout:
- **AdminSessionsPage** — list/lock/delete sessions
- **AdminPlayersPage** — list/rename/delete players, set tier
- **AdminRatingsPage** — ingest/revert/rebuild ratings
- **AdminTournamentsPage** — list/delete tournaments
- **AdminSeasonsPage** — manage rating seasons

### Ratings System

Backend (Go, `apps/api`):
- **Glicko-1-lite** rating engine with 8-tier ClassBands (D: 1000–1199, ..., A+: 2100+)
- `rating_events` → `rating_deltas` → `rating_players` pipeline
- Season system with `rating_config` (season_start, decay parameters, absent_policy)
- `absent_policy`: `skip_player` (default) — absent/skipped player excluded, game counts for others
- Auto-ingest locked sessions (ticker every 30 min)

Frontend:
- `apps/web/src/queries/ratings.ts` — React Query hooks for leaderboard, player detail, history
- `apps/web/src/components/ratings/` — `RatingTierBadge`, `RatingSparkline`, `CareerStats`
- `apps/web/src/config/ratingTiers.ts` — 8-band rating tier colors

### Tournament Components

`apps/web/src/components/tournament/`:
- `GroupAssignment.tsx` — numbered-slot UI for assigning pairs to groups.
- `GroupMatches.tsx` — enter scores for group stage matches.
- `BracketTab.tsx` — knockout bracket visualization.
- `StandingsTab.tsx` — standings table per group.
- `ScoreModal.tsx` — modal for score entry.
- `ScoreboardOverlay.tsx` — fullscreen scoreboard overlay.

### Queries Layer

`apps/web/src/queries/` is the single access point for all server state. No page or component imports fetch functions directly.

- `endpoints.ts` — raw fetch functions (`getSession`, `publishSession`, `listSessions`, `listPlayers`, `getPlayerStats`, `registerPlayer`, `deleteSession`, `unlockSession`, `getTournament`, `publishTournament`) + `RpcError` class. Internal to the layer — not re-exported from `index.ts`.
- `types.ts` — shared types: `CloudSnapshot`, `SessionMeta`, `PlayerSummary`, `PlayerStats`, re-exports `TournamentSnapshot`.
- `sessions.ts` — `useListSessions`, `useGetSession`, `usePublishSession`, `useTogglePlayed`, `useSetScore`, `useSwapPlayers`, `useSwapTeams`, `useSwapSlots`, `useSetAbsent`, `useReplacePlayer`, `useChangePlayer`, `useLockSession`, `useDeleteSession`, `useFetchSession`. Mutations own all cache logic (optimistic update, rollback-first error handling, smart invalidation).
- `players.ts` — `useListPlayers`, `useGetPlayerStats`.
- `tournament.ts` — `useGetTournament`, `useConfirmGroups`, `useSetTournamentScore`, `useResetTournament`, `useRegeneratePics`.
- `ratings.ts` — `useRatingLeaderboard`, `useRatingPlayer`, `useRatingHistory`.
- `index.ts` — barrel export of all hooks and types.

**Mutation call-site pattern** — destructure `{ mutate, isPending }` rather than storing the full mutation object:
```typescript
const { mutate: togglePlayed, isPending: togglePlayedPending } = useTogglePlayed(sessionId!)
togglePlayed(vars, { onSuccess: () => ..., onError: () => ... })
```

### Utilities

- `apps/web/src/utils/tournament.ts` — pure TS: `generateGroupMatches()`, `initKnockoutMatches()`, `propagateBracket()`, `computeGroupStandings()`, `assignGroupPics()`.
- `apps/web/src/utils/teamTournament.ts` — team tournament logic: `computeTeamStandings()`, `generateTeamDraw()`, `teamMatchOutcome()`, `teamMatchPoints()`.
- `apps/web/src/utils/teamTournamentPost.ts` — canvas post generator for team tournament standings (dark gradient frame).
- `apps/web/src/utils/standings.ts` — computes per-player W/L and point diff for a session.
- `apps/web/src/utils/shareUrl.ts` — encode/decode session state into URL hash (uses `lz-string` for compression).
- `apps/web/src/utils/share.ts` — canvas-to-blob and shareOrDownload utility (iOS Web Share API fallback).
- `apps/web/src/utils/swap.ts` — swap players between games, swap teams, change player logic.
- `apps/web/src/utils/slotSwap.ts` — swap game slots and detect cross-slot conflicts.
- `apps/web/src/utils/sessionSnapshot.ts` — snapshot mutation helpers.
- `apps/web/src/utils/playerStats.ts` — `computePlayerStats()` for play/sit/partner/opponent counts; `computeBackToBackRunBySlot()` for the `*N` chip marker.
- `apps/web/src/utils/quality.ts` — schedule quality scoring (`backToBackCount` aggregate for the banner).
- `apps/web/src/utils/placeholders.ts` — `isPlaceholderName()` regex for Free/TBD detection.
- `apps/web/src/utils/reconcilePlayers.ts` — player resolution during publish.
- `apps/web/src/utils/counter.ts` — play count tracking.
- `apps/web/src/utils/array.ts` — `shuffle()` (Fisher-Yates).
- `apps/web/src/utils/tally.ts` — shared tally row logic (wins, losses, pointsFor, pointsAgainst).
- `apps/web/src/utils/ordinal.ts` — `ordinal()` helper (1st, 2nd, 3rd).
- `apps/web/src/utils/resolvePlayers.ts` — player resolution helpers for publish-time identity reconciliation.
- `apps/web/src/utils/overlays.ts` — overlay utilities.
- `apps/web/src/config/tiers.ts` — 8-tier labels, colors, badge colors, active states.
- `apps/web/src/config/ratingTiers.ts` — 8-band rating tier colors and badge styles.
- `apps/web/src/config/instagramTemplates.ts` — Instagram post template assets and dimensions.

### Instagram Post Scripts

`apps/web/scripts/` contains Node.js automation (not part of the web app build):

- `generate-posts.mjs` — batch canvas rendering using `@napi-rs/canvas`.
- `post-instagram.mjs` — Playwright automation to upload generated posts to Instagram.

### Key Dependencies

- `@tanstack/react-query` ^5 — server state for sessions, players, and scores.
- `lz-string` ^1.5 — URL compression for share feature.
- `react-router-dom` ^7 — client-side routing.

### Styling

Tailwind v4 via the `@tailwindcss/vite` plugin (configured in [apps/web/vite.config.ts](apps/web/vite.config.ts)). Dark slate theme throughout; no separate CSS framework. No `tailwind.config.js` — Tailwind v4 uses auto-discovery.

### Deployment

[apps/web/vercel.json](apps/web/vercel.json) rewrites all routes to `index.html` for client-side routing. Frontend deploys on Vercel (Root Directory `apps/web`); backend deploys via webhook on the VPS. See the root [`README.md`](README.md).
