# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

```bash
npm run dev       # Start dev server (Vite HMR)
npm run build     # Type-check then build for production
npm run lint      # ESLint
npm run preview   # Preview production build locally
```

No test suite exists in this project.

## Architecture

This is a single-page React app (React 19, Vite, Tailwind v4, TypeScript) that generates optimised badminton match schedules for recreational sessions.

**User flow (4 steps, enforced by route guards in [App.tsx](src/App.tsx)):**
1. **Setup** (`/`) — configure courts, slot duration, court times, player count, tier count. Locks the session.
2. **Players** (`/players`) — add/edit players with name, gender, and tier (1–4).
3. **Constraints** (`/constraints`) — define "fix matches": pre-assigned pairings (fully or partially specified) that must appear in the schedule.
4. **Generate** (`/generate`) — run the scheduler, view the schedule, retry until quality is good.

**State** lives in a single Zustand store ([src/store/index.ts](src/store/index.ts)) persisted to `localStorage` under the key `badminton-store`. The store version is incremented (`version: 8`) and migration simply resets to defaults on any version mismatch. Mutating any player, fix match, or session field resets `schedule` and `lastResult` to `null` so stale results are never shown.

**Generator** ([src/generator/index.ts](src/generator/index.ts)) is pure TypeScript with no external dependencies. Key algorithm:
- Scores a game by `partnerRepeat × 3 + opponentRepeat + tierDiff × 2` — lower is better.
- Two "A-side-only" fix matches can be *merged* into a single game (one pair becomes Team A, the other Team B) to pack the schedule more efficiently.
- Fix matches are placed first (most specified first), then remaining slots are filled greedily by choosing players with the lowest projected play count, preferring those who sat out recently.
- `bestGrouping` runs 40 random shuffles and picks the grouping with the lowest aggregate score.
- `courtOffsets` handle courts that start at different times (e.g. Court B opens an hour later than Court A).

**`GeneratePage`** ([src/pages/GeneratePage.tsx](src/pages/GeneratePage.tsx)) contains most of the display logic:
- `QualityBanner` — grades the schedule on play-count spread, match balance, partner/opponent variety, and back-to-back games.
- "Retry until good" runs up to 30 generations and keeps the best scoring result.
- `SummaryModal` — a full-screen overlay showing a compact checklist view of the schedule (tap to mark games as played).
- Back-to-back games are flagged with `*` on player chips.

**Routing:** `RequireSession` redirects to `/` if the session isn't locked; `RequirePlayers` additionally checks that the exact `playerCount` players have been entered before allowing access to `/constraints` or `/generate`.

**Styling:** Tailwind v4 via the `@tailwindcss/vite` plugin (configured in [vite.config.ts](vite.config.ts)). Dark slate theme throughout; no separate CSS framework.

**Deployment:** [vercel.json](vercel.json) rewrites all routes to `index.html` for client-side routing.
