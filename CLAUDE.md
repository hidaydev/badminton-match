# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

```bash
npm run dev       # Start dev server (Vite HMR)
npm run build     # Type-check then build for production
npm run lint      # ESLint
npm run preview   # Preview production build locally
```

No formal test framework, but compact regression tests exist via `node:test`:

```bash
npm run check          # Types + lint + tailwind + regression tests
npm run check:smoke    # Live Supabase RPC smoke tests
npm run check:regression  # Regression tests only (node:test)
npx playwright test    # E2E tests (Playwright, requires dev server)
```

## Architecture

This is a single-page React app (React 19, Vite, Tailwind v4, TypeScript) that generates optimised badminton match schedules for recreational sessions. It has grown to also include tournament management, session history, and player career tracking.

### Core Session Flow

**User flow (4 steps, enforced by route guards in [App.tsx](src/App.tsx)):**
1. **Setup** (`/session/new`) — configure courts, slot duration, court times, player count, tier count. Locks the session.
2. **Players** (`/session/players`) — add/edit players with name, gender, and tier (1–4).
3. **Constraints** (`/session/constraints`) — define "fix matches": pre-assigned pairings (fully or partially specified) that must appear in the schedule.
4. **Generate** (`/session/generate`) — run the scheduler, view the schedule, retry until quality is good.

**Routing:** `RequireSession` redirects to `/session/new` if the session isn't locked; `RequirePlayers` additionally checks that the exact `playerCount` players have been entered before allowing access to `/session/constraints` or `/session/generate`.

**Home page** shows 5 menu items: Create Session, Sessions, Player History, Tournament, Instagram Post.

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

- **GeneratePage** ([src/pages/GeneratePage.tsx](src/pages/GeneratePage.tsx)) — 739 lines. `QualityBanner` grades the schedule; "Retry until good" runs up to 30 generations (yields to browser via `requestAnimationFrame` between iterations); `SummaryModal` is a full-screen overlay with a checklist view (tap to mark games as played, support for absent players). Back-to-back games flagged with `*` on player chips. Debounces cloud publishes (300 ms trailing, 1s max delay) and flushes on unmount.
- **TournamentPage** ([src/pages/TournamentPage.tsx](src/pages/TournamentPage.tsx)) — tabbed UI with three tabs: **Groups** (assign 16 pairs to numbered slots #1–#16 across 4 groups via tap-slot-then-pick-pair; switches to GroupMatches when locked), **Bracket** (horizontal scrolling QF→SF→Final knockout bracket with connector lines), **Standings** (per-group W/L, point diff, head-to-head table). Local draft group state is `Record<GroupId, (string | null)[]>` — always 4 elements, null for empty slots.
- **SessionListPage** ([src/pages/SessionListPage.tsx](src/pages/SessionListPage.tsx)) — browse past cloud-synced sessions with date filter.
- **PlayerHistoryPage** ([src/pages/PlayerHistoryPage.tsx](src/pages/PlayerHistoryPage.tsx)) — list all players from cloud history.
- **PlayerDetailPage** ([src/pages/PlayerDetailPage.tsx](src/pages/PlayerDetailPage.tsx)) — per-player career stats (top partners, opponents).
- **SharedSessionPage** ([src/pages/SharedSessionPage.tsx](src/pages/SharedSessionPage.tsx)) — view/manage a cloud-synced shared session (`/s/:sessionId`).
- **InstagramPostPage** ([src/pages/InstagramPostPage.tsx](src/pages/InstagramPostPage.tsx)) — HTML5 Canvas editor for creating branded Instagram posts (1080×1350) and stories (1080×1920). User uploads a photo, drags to reposition, pinch-to-zoom, picks a session date, then exports via bottom sheet. Canvas layers: user photo (cover-fill) → date graphic → chevrons ornament → header band → footer PNG. Template assets and dimensions are defined in [src/config/instagramTemplates.ts](src/config/instagramTemplates.ts).

### Tournament Components

`src/components/tournament/`:
- `GroupAssignment.tsx` — numbered-slot UI (slots #1–#16) for assigning pairs to groups. Interaction: tap an empty slot to select it (highlights amber), then tap a pair chip from the unassigned pool to place it. Slots are globally numbered: A=#1–4, B=#5–8, C=#9–12, D=#13–16. Local draft state in `TournamentPage` uses `(string | null)[]` of fixed length 4 per group; nulls are filtered before cloud confirm.
- `GroupMatches.tsx` — enter scores for group stage round-robin matches.
- `BracketTab.tsx` — knockout bracket visualization.
- `StandingsTab.tsx` — standings table per group.
- `ScoreModal.tsx` — modal for score entry.
- `ScoreboardOverlay.tsx` — fullscreen scoreboard overlay for tournament matches (wraps ScoreboardPage).

### Queries Layer

`src/queries/` is the single access point for all server state. No page or component imports fetch functions directly.

- `endpoints.ts` — raw fetch functions (`getSession`, `publishSession`, `listSessions`, `listPlayers`, `getPlayerStats`, `registerPlayer`, `deleteSession`, `unlockSession`, `getTournament`, `publishTournament`) + `TOURNAMENT_ID` constant and `RpcError` class. Internal to the layer — not re-exported from `index.ts`.
- `types.ts` — shared types: `CloudSnapshot`, `SessionMeta`, `PlayerSummary`, `PlayerStats`, re-exports `TournamentSnapshot`.
- `sessions.ts` — `useListSessions`, `useGetSession`, `usePublishSession`, `useTogglePlayed`, `useSetScore`, `useSwapPlayers`, `useSwapTeams`, `useSwapSlots`, `useSetAbsent`, `useReplacePlayer`, `useChangePlayer`, `useLockSession`, `useDeleteSession`, `useFetchSession`. Mutations own all cache logic (optimistic update, rollback-first error handling, smart invalidation). `onSuccess` uses `fetchQuery` (not `setQueryData`) to prevent race conditions; `onError` rolls back before refetch. UI callbacks are passed by components via `mutate(vars, { onSuccess, onError })`.
- `players.ts` — `useListPlayers`, `useGetPlayerStats`.
- `tournament.ts` — `useGetTournament`, `useConfirmGroups`, `useSetTournamentScore`, `useResetTournament`, `useRegeneratePics`.
- `index.ts` — barrel export of all hooks and types. Also re-exports `TOURNAMENT_ID` for components that need to invalidate the tournament query manually.

**Mutation call-site pattern** — destructure `{ mutate, isPending }` rather than storing the full mutation object:
```typescript
const { mutate: togglePlayed, isPending: togglePlayedPending } = useTogglePlayed(sessionId!)
togglePlayed(vars, { onSuccess: () => ..., onError: () => ... })
```

### Utilities

- `src/utils/tournament.ts` — pure TS: `generateGroupMatches()` (6 round-robin games per group), `initKnockoutMatches()`, `propagateBracket()`, `computeGroupStandings()`, `assignGroupPics()`.
- `src/utils/standings.ts` — computes per-player W/L and point diff for a session.
- `src/utils/shareUrl.ts` — encode/decode session state into URL hash (uses `lz-string` for compression).
- `src/utils/swap.ts` — swap players between games, swap teams, change player logic, conflict detection.
- `src/utils/slotSwap.ts` — swap game slots and detect cross-slot conflicts.
- `src/utils/sessionSnapshot.ts` — snapshot mutation helpers (toggle played, set score, swap players/teams/slots, set absent, replace player name, change player).
- `src/utils/playerStats.ts` — `computePlayerStats()` for play/sit/partner/opponent counts (shared by GeneratePage and SummaryModal).
- `src/utils/ordinal.ts` — `ordinal()` helper (1st, 2nd, 3rd).
- `src/utils/resolvePlayers.ts` — player resolution helpers (`findUnresolvedPlayers`, `buildResolveResult`) for publish-time identity reconciliation.
- `src/config/tiers.ts` — tier labels, colors, badge colors shared across GeneratePage, PlayersPage, ConstraintsPage.

### Instagram Post Scripts

`scripts/` contains Node.js automation (not part of the web app build):

- `generate-posts.mjs` — batch canvas rendering using `@napi-rs/canvas`. Scans `~/Downloads/Majadu/Best/{YYYY-MM-DD}/1.jpg`, outputs `post.jpg` (1080×1350) and `story.jpg` (1080×1920) per folder. Handles landscape (contain + blur BG) and portrait (cover) photos.
- `post-instagram.mjs` — Playwright automation to upload generated posts to Instagram. Saves browser session to `scripts/.instagram-session.json` and tracks posted dates in `scripts/.instagram-posted.json` to avoid duplicates.

### Key Dependencies

- `@tanstack/react-query` ^5 — server state for sessions, players, and scores.
- `lz-string` ^1.5 — URL compression for share feature.
- `react-router-dom` ^7 — client-side routing.

### Styling

Tailwind v4 via the `@tailwindcss/vite` plugin (configured in [vite.config.ts](vite.config.ts)). Dark slate theme throughout; no separate CSS framework. No `tailwind.config.js` — Tailwind v4 uses auto-discovery.

### Deployment

[vercel.json](vercel.json) rewrites all routes to `index.html` for client-side routing.
