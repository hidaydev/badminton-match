# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

```bash
npm run dev       # Start dev server (Vite HMR)
npm run build     # Type-check then build for production
npm run lint      # ESLint
npm run preview   # Preview production build locally
```

Regression tests exist via `node:test` (pure logic — retry policy, generator quality, snapshot helpers, tournament bracket):

```bash
npm run check              # Types + lint + tailwind + regression tests
npm run check:regression   # Regression tests only (node:test)
```

Backend tests live in the `majadu-api` repo (`go test ./...` — unit + handler + integration test env-guarded via `MAJADU_TEST_DATABASE_URL`).

## Architecture

This is a single-page React app (React 19, Vite, Tailwind v4, TypeScript) that generates optimised badminton match schedules for recreational sessions. It has grown to also include tournament management, session history, ratings/leaderboard, and admin tools.

### Core Session Flow

**User flow (4 steps, enforced by route guards in [App.tsx](src/App.tsx)):**
1. **Setup** (`/session/new`) — configure courts, slot duration, court times, player count, tier count (8-tier: D, D+, C, C+, B, B+, A, A+). Locks the session.
2. **Players** (`/session/players`) — add/edit players with name, gender, and tier (1–8). Tier picker is read-only for registered players (canonical tier from backend).
3. **Constraints** (`/session/constraints`) — define "fix matches": pre-assigned pairings (fully or partially specified) that must appear in the schedule.
4. **Generate** (`/session/generate`) — run the scheduler, view the schedule, retry until quality is good.

**Routing:** `RequireSession` redirects to `/session/new` if the session isn't locked; `RequirePlayers` additionally checks that the exact `playerCount` players have been entered before allowing access to `/session/constraints` or `/session/generate`.

**Home page** shows 6 cards: Sessions, Ratings, Scoreboard, Tournament, IG Post, Admin. Admin section (5 cards: Sessions, Players, Ratings, Tournaments, Seasons) appears after login.

### State Management

One Zustand store, persisted to `localStorage`:

- **Main store** ([src/store/index.ts](src/store/index.ts)) — key `badminton-store`, `version: 14`. Holds session config, players, fix matches, schedule, played games, game scores, absent players, and `cloudSessionId`. Mutating any player, fix match, or session field resets `schedule` and `lastResult` to `null`.

Migration resets to defaults on any version mismatch. The tournament store was removed — TournamentPage uses React Query directly.

### Generator

[src/generator/index.ts](src/generator/index.ts) is pure TypeScript with no external dependencies. Key algorithm:
- Scores a game by `partnerRepeat × 3 + opponentRepeat + tierDiff × 2` — lower is better.
- Two "A-side-only" fix matches can be *merged* into a single game (one pair becomes Team A, the other Team B) to pack the schedule more efficiently.
- Fix matches are placed first (most specified first), then remaining slots are filled greedily by choosing players with the lowest projected play count, preferring those who sat out recently.
- `bestGrouping` runs 40 random shuffles and picks the grouping with the lowest aggregate score.
- `courtOffsets` handle courts that start at different times (e.g. Court B opens an hour later than Court A).

### Pages

- **GeneratePage** ([src/pages/GeneratePage.tsx](src/pages/GeneratePage.tsx)) — `QualityBanner` grades the schedule; "Retry until good" runs up to 30 generations; `SummaryModal` is a full-screen overlay with a checklist view (tap to mark games as played, support for absent players). Debounces cloud publishes (300 ms trailing, 1s max delay) and flushes on unmount.
- **RatingsPage** ([src/pages/RatingsPage.tsx](src/pages/RatingsPage.tsx)) — leaderboard with server-side pagination (100 per page), "Load more" button. Shows tier badge, rating, trend, games count. Peak rating removed from list (shown in player detail).
- **RatingPlayerPage** ([src/pages/RatingPlayerPage.tsx](src/pages/RatingPlayerPage.tsx)) — per-player rating detail: stat cards (peak, games, W-L, tier), sparkline trend, recent matches (paginated, 5/page), career stats from `CareerStats.tsx`.
- **TournamentPage** ([src/pages/TournamentPage.tsx](src/pages/TournamentPage.tsx)) — tabbed UI for classic tournament: **Groups**, **Bracket**, **Standings**.
- **TeamTournamentPage** ([src/pages/TeamTournamentPage.tsx](src/pages/TeamTournamentPage.tsx)) — tabbed UI for team tournament: **Standings** (editable team names, member list, crown for champion), **Schedule** (score entry per partai), **Final** (champion banner). Includes Instagram post export.
- **SessionListPage** ([src/pages/SessionListPage.tsx](src/pages/SessionListPage.tsx)) — browse past cloud-synced sessions with date filter.
- **SharedSessionPage** ([src/pages/SharedSessionPage.tsx](src/pages/SharedSessionPage.tsx)) — view/manage a cloud-synced shared session (`/s/:sessionId`).
- **InstagramPostPage** ([src/pages/InstagramPostPage.tsx](src/pages/InstagramPostPage.tsx)) — HTML5 Canvas editor for creating branded Instagram posts (1080×1350) and stories (1080×1920).
- **NewTournamentWizard** ([src/pages/NewTournamentWizard.tsx](src/pages/NewTournamentWizard.tsx)) — 3-step wizard for creating tournaments. Classic: 16 pairs → 4 groups. Team: 36 players (6 classes × 6 teams) with manual team assignment.

### Admin Pages (`src/pages/admin/`)

5 separate admin pages, each with `AdminPageShell` layout:
- **AdminSessionsPage** — list/lock/delete sessions
- **AdminPlayersPage** — list/rename/delete players, set tier
- **AdminRatingsPage** — ingest/revert/rebuild ratings
- **AdminTournamentsPage** — list/delete tournaments
- **AdminSeasonsPage** — manage rating seasons

### Ratings System

Backend (Go, `majadu-api` repo):
- **Glicko-1-lite** rating engine with 8-tier ClassBands (D: 1000–1199, ..., A+: 2100+)
- `rating_events` → `rating_deltas` → `rating_players` pipeline
- Season system with `rating_config` (season_start, decay parameters)
- Auto-ingest on session lock (ticker every 30 min)

Frontend:
- `src/queries/ratings.ts` — React Query hooks for leaderboard, player detail, history
- `src/components/ratings/` — `RatingTierBadge`, `RatingSparkline`, `CareerStats`
- `src/config/ratingTiers.ts` — 8-band rating tier colors

### Tournament Components

`src/components/tournament/`:
- `GroupAssignment.tsx` — numbered-slot UI for assigning pairs to groups.
- `GroupMatches.tsx` — enter scores for group stage matches.
- `BracketTab.tsx` — knockout bracket visualization.
- `StandingsTab.tsx` — standings table per group.
- `ScoreModal.tsx` — modal for score entry.
- `ScoreboardOverlay.tsx` — fullscreen scoreboard overlay.

### Queries Layer

`src/queries/` is the single access point for all server state. No page or component imports fetch functions directly.

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

- `src/utils/tournament.ts` — pure TS: `generateGroupMatches()`, `initKnockoutMatches()`, `propagateBracket()`, `computeGroupStandings()`, `assignGroupPics()`.
- `src/utils/teamTournament.ts` — team tournament logic: `computeTeamStandings()`, `generateTeamDraw()`, `teamMatchOutcome()`, `teamMatchPoints()`.
- `src/utils/teamTournamentPost.ts` — canvas post generator for team tournament standings (dark gradient frame).
- `src/utils/standings.ts` — computes per-player W/L and point diff for a session.
- `src/utils/shareUrl.ts` — encode/decode session state into URL hash (uses `lz-string` for compression).
- `src/utils/share.ts` — canvas-to-blob and shareOrDownload utility (iOS Web Share API fallback).
- `src/utils/swap.ts` — swap players between games, swap teams, change player logic.
- `src/utils/slotSwap.ts` — swap game slots and detect cross-slot conflicts.
- `src/utils/sessionSnapshot.ts` — snapshot mutation helpers.
- `src/utils/playerStats.ts` — `computePlayerStats()` for play/sit/partner/opponent counts.
- `src/utils/quality.ts` — schedule quality scoring.
- `src/utils/placeholders.ts` — `isPlaceholderName()` regex for Free/TBD detection.
- `src/utils/reconcilePlayers.ts` — player resolution during publish.
- `src/utils/counter.ts` — play count tracking.
- `src/utils/array.ts` — `shuffle()` (Fisher-Yates).
- `src/utils/tally.ts` — shared tally row logic (wins, losses, pointsFor, pointsAgainst).
- `src/utils/ordinal.ts` — `ordinal()` helper (1st, 2nd, 3rd).
- `src/utils/resolvePlayers.ts` — player resolution helpers for publish-time identity reconciliation.
- `src/utils/overlays.ts` — overlay utilities.
- `src/config/tiers.ts` — 8-tier labels, colors, badge colors, active states.
- `src/config/ratingTiers.ts` — 8-band rating tier colors and badge styles.
- `src/config/instagramTemplates.ts` — Instagram post template assets and dimensions.

### Instagram Post Scripts

`scripts/` contains Node.js automation (not part of the web app build):

- `generate-posts.mjs` — batch canvas rendering using `@napi-rs/canvas`.
- `post-instagram.mjs` — Playwright automation to upload generated posts to Instagram.

### Key Dependencies

- `@tanstack/react-query` ^5 — server state for sessions, players, and scores.
- `lz-string` ^1.5 — URL compression for share feature.
- `react-router-dom` ^7 — client-side routing.

### Styling

Tailwind v4 via the `@tailwindcss/vite` plugin (configured in [vite.config.ts](vite.config.ts)). Dark slate theme throughout; no separate CSS framework. No `tailwind.config.js` — Tailwind v4 uses auto-discovery.

### Deployment

[vercel.json](vercel.json) rewrites all routes to `index.html` for client-side routing.
