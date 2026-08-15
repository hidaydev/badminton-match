# Current Status

Last updated: 2026-07-30 (post-clean-code-audit + design-system-revamp)

This is the fastest handover file for continuing work on this repository.

## Branch

- current working branch: `dev` (di-rename dari `ui-revamp` pada 2026-08-15, konsisten dengan backend)

## Core decision record

- `badminton-match` has completed its runtime move from Google Apps Script /
  Google Sheets to Supabase on this branch
- same Supabase project as `MDEF`
- normalized operational schema: `bm`
- no `MDEF` code changes for now
- no shared core tables with `MDEF`
- normalized `bm` runtime for local app usage
- this app should rely only on `bm` as its runtime schema

## What is already done

### Database migration

Applied migrations (53 original migrations squashed into 3 files):

- [`supabase/migrations/20260616_000001_schema.sql`](../../supabase/migrations/20260616_000001_schema.sql) — all DDL: tables, indexes, constraints, triggers, grants
- [`supabase/migrations/20260616_000002_functions.sql`](../../supabase/migrations/20260616_000002_functions.sql) — all 26 functions in final form
- [`supabase/migrations/20260616_000003_seeds.sql`](../../supabase/migrations/20260616_000003_seeds.sql) — seeds, legacy backfill, data fixes, validation

See [migration-tracking.md](migration-tracking.md) for squash details.

Created:

- `bm.sessions`
- `bm.players`
- `bm.player_aliases`
- `bm.tournaments`

RPC functions created for local app usage:

- `bm.publish_session`
- `bm.get_session`
- `bm.list_sessions`
- `bm.list_players`
- `bm.get_player_stats`
- `bm.register_player`
- `bm.publish_tournament`
- `bm.get_tournament`
- `bm.delete_session` (admin-only)
- `bm.delete_player` (admin-only)
- `bm.unlock_session` (admin-only, service_role only, not wired to UI)

The local app now targets the underlying `bm.*` functions directly through the
`bm` PostgREST profile.

Main practical state now:

- aggregate identity is UUID-first
- session publish is internal-id-first
- app runtime depends on `bm` only
- `badminton_match` is now historical migration context, not a live runtime target
- active relational graph in `bm` is UUID-first
- exposed-schema/runtime drift was fixed during verification
- session lock enforcement is active (`publish_session` rejects writes when `locked=true` or any non-draft status)
- delete session and unlock session are admin-only RPCs (not wired to UI)
- `list_sessions` returns `locked` status column
- `register_player` is TOCTOU-safe (re-queries alias after INSERT)
- `unlock_session` bumps version when resetting to draft
- `delete_session` rejects deletion of non-draft (locked) sessions

### Frontend migration

The query layer has been switched from Apps Script to Supabase RPCs.

Main file:

- [`src/queries/endpoints.ts`](../../src/queries/endpoints.ts)

### Refactoring and extraction (2026-07-15)

Code quality improvements completed:

- **Deleted `store/tournament.ts`** — dead code, never imported (TournamentPage uses React Query)
- **Renamed `replacementPlayerId` → `newName`** in `utils/swap.ts` and `utils/sessionSnapshot.ts` for clarity
- **Extracted tier constants** to `config/tiers.ts` — shared across GeneratePage, PlayersPage, ConstraintsPage
- **Extracted `ordinal()`** to `utils/ordinal.ts` — shared across SummaryModal, PlayerMatchDetailSheet, InstagramPostPage
- **Extracted `computePlayerStats()`** to `utils/playerStats.ts` — shared across GeneratePage and SummaryModal
- **Fixed `useStore()` selectors** in SetupPage, PlayersPage, ConstraintsPage — prevents unnecessary re-renders
- **Decomposed SummaryModal** (1575 → 1327 lines) — extracted `ConfirmBars.tsx`, `ActionsMenu.tsx`, `PlayerStatsPanel.tsx`
- **Player Stats (published session)** — standalone mode with 2-column grid, no target/ideal plays, absent players greyed with badge and sorted at bottom, includes all players from schedule
- **Change Player improvements** — cross-slot conflict detection, confirmation bar (consistent with swap/absent pattern), back-to-back warning in confirm bar
- **Change Player restricted to published sessions** — removed from GeneratePage, only available in SharedSessionPage

### Concurrency and race condition fixes (2026-07-16)

- **onSuccess race condition fix** — All 15 mutation hooks (11 session + 4 tournament) now use `fetchQuery` instead of `setQueryData(server_response)` in `onSuccess` (except `useDeleteSession` which uses `onSettled`). This prevents race conditions where a subsequent mutation's optimistic update gets overwritten by a stale server response.
- **Smart query invalidation** — Split into `invalidateSessionQueries` (7 hooks that don't change player data) and `invalidateAllQueries` (4 hooks that do: change player, replace player, set absent, delete session). Avoids unnecessary N+1 refetches of individual player stat queries.
- **Debounced publish flush on unmount** — `GeneratePage` now flushes pending cloud publish when component unmounts (fire-and-forget via raw `publishSession` endpoint). Debounce is 300ms trailing with 1s max delay.
- **Score tapping disabled during save** — `ScoreboardPage` now disables score tapping while save is in progress.
- **All session/tournament mutation hooks** — rollback-first error handling with async/await in `onError`.
- **`registerPlayer` return value** — `useChangePlayer` uses the returned player UUID (not the name string) for identity.
- **`applyChange` single-position replacement** — only changes the specific position in the target game, not all occurrences globally.
- **Change Player snapshot integrity** — adds player to `snapshot.players[]` with `playerCount` update; rebuilds players from schedule to prevent orphaned UUIDs; uses existing player UUID from snapshot instead of `registerPlayer` to prevent duplicate canonical names.
- **Store version bumped to 14** — resets stale locked state from prior versions.

### Silent error handling (2026-07-16)

Non-critical errors in InstagramPostPage, ScoreboardPage, ShareButton, HomePage, and SharedSessionPage now use silent handling (`catch (_error) { void _error }` or `catch { /* skip */ }`) to prevent console noise for expected failures (fullscreen lock, clipboard, image load failures).

### Cleanup (2026-07-16)

- **Deleted `detectChangeConflict`** from `swap.ts` — dead code, never imported
- **53 SQL migrations consolidated into 3 files** — removed 16,544 lines of incremental migration history
- **10 handbook files archived**, 3 updated, 1 new (`migration-tracking.md`)

### Documentation baseline

Current-state docs exist under:

- [`docs/handbook/`](.)

Historical implementation archive remains under:

- [`docs/superpowers/`](../superpowers)

### Design system & accessibility (2026-07-20)

Formalized design system, WCAG compliance, and performance optimization for mobile PWA.

### Clean code audit — Phase 1–12 complete (2026-07-26)

Comprehensive clean code / clean architecture audit covering 134 of 151 items across 12 phases (5 items partial, 12 remaining out of scope):

- **Phase 1: Break Circular Dependency** — extracted domain types to `types/index.ts`, time utilities to `utils/time.ts`. `generator/` and `utils/` now have zero imports from `store/` or `queries/`.
- **Phase 2: Extract Domain from Presentation** — canvas drawing consolidated to `utils/canvasPost.ts`, quality analysis to `utils/quality.ts`, player-rebuild logic to `utils/reconcilePlayers.ts`.
- **Phase 3: DRY Consolidation** — shared `bumpCoOccurrence()` counter, unified `computeStandings()` via `utils/tally.ts`, `useOptimisticSessionMutation` factory hook (eliminated boilerplate in 7+ mutation hooks), shared iOS share/download utility, shared overlay image loader.
- **Phase 4: SRP — Store/SummaryModal/Hooks** — store decomposed into 5 slices (session, players, schedule, game, ui), SummaryModal uses discriminated union modes, extracted `ConfirmBars`, `ActionsMenu`, `PlayerStatsPanel`, `SlotGameCard`, `PlayerMatchDetailSheet`, `ScheduleComponents`.
- **Phase 5: OCP — Generator Extensibility** — generator phases extracted to named functions, scoring weights injectable via config, generic `combinations()` utility replaces hardcoded blocks.
- **Phase 6: LSP** — `CourtTime` validation, `FixMatch` discriminated union, mutation hook signatures unified.
- **Phase 7: ISP** — `CloudSnapshot` decoupled from `AppState`, `generate()` accepts minimal interface.
- **Phase 8: DIP** — `domain/ports/` repository interfaces created, `GeneratePage` uses `useDebouncedPublish` hook.
- **Phase 9: Function/Component Design** — god functions decomposed, parameter objects replace long param lists, inline components extracted from ConstraintsPage and ScoreboardPage.
- **Phase 10: Naming & Type Hardening** — descriptive variable names throughout, branded types (`PlayerId`, `TimeString`, `GameKey`), `strict: true` enabled.
- **Phase 11: Magic Numbers & Constants** — `config/generator.ts`, `config/canvas.ts`, `config/tiers.ts` extract all named constants.
- **Phase 12: Dead Code & Cleanup** — removed 5 unused UI components, fixed devDependencies, dropped redundant indexes, fixed seed parity queries.

Remaining: Phase 13 (Database Security — RLS, auth) and Phase 14 (Infrastructure Hardening — timeouts, retries, type validation) are out of scope for current work.

See [CLEANCODE_BACKLOG.md](../../CLEANCODE_BACKLOG.md) for full tracking (134/151 verified, 5 partial).

**Typography:**
- Body font: IBM Plex Sans (400, 500, 600, 700) — replaces system-ui
- Monospace: IBM Plex Mono (400, 500) — replaces default monospace
- Instagram canvas decorative: Granesta + Edosz (unchanged, loaded on-demand)
- Dead fonts removed: Anton, Third Rail, Rushon Ground
- Google Fonts loaded non-render-blocking (`media="print" onload`)

**WCAG Contrast Fixes (2 rounds):**
- Round 1: All `text-slate-600` (51 instances) → `text-slate-500`, all `text-slate-700` (6) → `text-slate-500`
- Round 2 (audit): All `text-slate-500` (100+ instances) → `text-slate-400` (~7.1:1 on dark bg)
- Hover states adjusted: `hover:text-slate-300` → `hover:text-slate-200`
- Small text on `bg-slate-800` upgraded to `text-slate-300` (~4.6:1)
- Body color fixed: `#e2e8f0` → `#f1f5f9` (matches `--color-fg` token)

**Accessibility (Mobile-First):**
- `focus-visible:ring-2` on all form inputs (NOT `focus:ring` — no tap flash on mobile)
- `aria-label` on all icon-only buttons (ScoreboardPage, PlayersPage, ConstraintsPage, ConfirmBars, PlayerMatchDetailSheet)
- `role="dialog"` + `aria-modal="true"` on all modals (SummaryModal, InstallModal, ScoreModal, ResolvePlayersModal, ShareButton, PlayerMatchDetailSheet, UpdateBanner)
- `aria-live="polite"` on error toasts (GeneratePage, SharedSessionPage, TournamentPage)
- `aria-label` on score inputs (ScoreboardPage, SummaryModal)
- `prefers-reduced-motion` media query in index.css
- Touch target fixes: tier picker (min-w-8 h-8), delete button (p-2), action buttons (px-2.5 py-1.5)
- ScoreboardPage: `role="button" tabIndex={0}` on score tap zones for keyboard accessibility
- ActionsMenu: `aria-expanded`, `aria-haspopup`, `role="menu"`, `role="menuitem"`
- ScoreboardPage: `<main>` landmark added

**Design Tokens (Tailwind v4 `@theme`):**
- `--color-ground` (#0f172a) → `bg-ground` — page background
- `--color-surface` (#1e293b) → `bg-surface` — cards
- `--color-elevated` (#334155) → `bg-elevated` — inputs
- `--color-fg` (#f1f5f9) → `text-fg` — primary text
- `--color-fg-dim` (#94a3b8) → `text-fg-dim` — dimmed text (WCAG AA)
- `--color-accent` (#fbbf24) → `text-accent` — brand color
- `--color-border` (#475569) → `border-border` — borders
- Tokens actively adopted across all pages and components
- JS tokens in `src/config/tokens.ts` for programmatic access

**Reusable Components:**
- `src/components/summary/ConfirmBars.tsx` — 5 fixed bottom confirm bars
- `src/components/summary/ActionsMenu.tsx` — actions dropdown
- `src/components/summary/PlayerStatsPanel.tsx` — player stats display
- `src/components/summary/SlotGameCard.tsx` — individual game card
- `src/components/summary/PlayerMatchDetailSheet.tsx` — player match detail
- `src/components/generate/ScheduleComponents.tsx` — QualityBanner, PlayerChip, TierBalance, ScheduleView

**Performance Optimization:**
- Code splitting: React.lazy() for ScoreboardPage, InstagramPostPage, TournamentPage, SharedSessionPage
- Initial JS: 154 KB → 107 KB gzip (30% reduction)
- Logo: 1.3 MB PNG → 14.5 KB (192px) + 88.1 KB (512px)
- Decorative fonts (Granesta/Edosz): removed preload, loaded on-demand via @font-face
- Google Fonts: non-render-blocking, removed unused weight 700

**Documentation:**
- `docs/design-system.md` — complete design system reference

**E2E Testing (Playwright):**
- `e2e/revamp.spec.ts` — 15 tests covering revamp changes
- Config: `playwright.config.ts` (mobile viewport, Chromium headless)
- Run: `npx playwright test`
- Tests:
  - Homepage: no errors, logo renders, IBM Plex Sans loaded, token colors applied, navigation grid
  - Scoreboard: code-split load, keyboard accessibility, aria-labels
  - Session Setup: focus-visible ring, semantic tokens
  - Players: touch target sizes
  - ARIA: `<main>` landmark, aria-labels
  - Images: no broken image responses
  - Reduced Motion: `prefers-reduced-motion` CSS present

## What has been verified

Verified against the real Supabase project:

1. create small test session
2. publish session
3. open shared session link
4. mark one game played
5. enter score
6. read back:
   - sessions list
   - player list
   - player stats
7. backfill normalized `bm` session data from legacy snapshots
8. verify summary parity and full snapshot parity
9. verify local app reads after removing legacy exposed-schema assumptions
10. run compact static + regression suite locally
11. run live Supabase smoke suite end to end:
   - session list
   - player list
   - session publish/version flow
   - player stats RPC
   - tournament publish/version flow

Verified result:

- local app session flow works against `bm`
- local app tournament flow is wired to `bm`
- player stats query works on Supabase
- `npm run check` passes on this branch
- `npm run check:smoke` passes against the configured Supabase project
- normalized session parity was verified during migration work
- Google Sheets is no longer required for the tested local session flow
- legacy runtime dependency has been removed from the local app path

## What is not done yet

1. production security hardening (partial: session lock, delete lock check, publish lock check all non-draft statuses delivered)
2. formal long-term export boundary for `MDEF`
3. broader end-to-end/UI regression coverage beyond the compact RPC/writeflow suite

## Important operational truth

The persistence migration arc is effectively closed.

It is accurate to say:

- Google Sheets is no longer the active runtime direction
- `badminton_match` served as the landing bridge
- `bm` is now the only runtime schema target for this app

It is still not accurate to say:

- everything is fully hardened for production rollout

Operational note:

- if a schema is dropped from the database, it must also be removed from
  Supabase `Exposed schemas`
- otherwise PostgREST can return `PGRST002` schema cache errors even when app
  code is correct

## Historical backfill reality

The branch has already completed the practical bridge from legacy snapshot
history into `bm`.

What still matters:

- historical Google Sheets / Apps Script details remain relevant as origin
  context
- they are no longer required for the active local runtime path
- future historical imports, if any, should target `bm`-compatible shapes rather
  than revive `badminton_match` as an application dependency

## Latest important commits

These are the main migration/doc checkpoints so far:

- `c9c21a3` — `refactor: clean code audit + bug hunt (Phase 1-12, 92% backlog complete)`
- `99525cf` — `chore: sync supabase migrations from remote (db dump --schema bm)`
- `74d8e33` — `feat: graphify`
- `baffbb4` — `test: add Playwright E2E tests for design system revamp`
- `6c79cb7` — `feat: design system, WCAG accessibility, and performance overhaul`
- `da02b91` — `Add Supabase schema and RPC query layer`
- `1b5c835` — `Add project baseline and migration docs`
- `f38e038` — `Organize docs into handbook and archive`
- `32d0593` — `Remove duplicated SQL from docs`
- `89dd9c2` — `feat: add delete session button + fix IG leaderboard absent bug`
- `a0b6a2b` — `feat: editable court names after lock + edit schedule before share`
- `3aff325` — `feat: manual match + time assignment (pinned fix matches)`
- `032711b` — `feat: show player stats in shared session schedule tab`
- `19ffbf2` — `feat: lock session feature`
- `823a940` — `fix: session lock enforcement uses status column`
- `884a406` — `fix: show Locked badge when session is locked`
- `74e0ac9` — `fix: set locked flag in both CloudSnapshot and session object`
- `ca520ff` — `fix: audit cleanup - locked field, unlock_session, list_sessions, mutations, docs`
- `2d00b1e` — `feat: change player feature + fix play count on-the-fly computation`
- `6739460` — `fix: detectTeamSwapConflict false positive on same-game team swaps + mode exits cleanup`
- `3f75c35` — `fix: critical + medium audit cleanup (16 issues)`
- `9abb7d7` — `fix: backend audit cleanup (6 issues)`
- `4395af3` — `fix: low severity cleanup (4 issues)`
- (latest session) — `refactor: extract shared utilities, decompose SummaryModal, fix selectors, remove dead code`
- (latest session) — `fix: race condition in onSuccess (fetchQuery), debounced publish flush, score tap guard, squash migrations`
- (latest session) — `fix: change player snapshot integrity, applyChange single-position, registerPlayer return value, store v14 bump`
- (latest session) — `refactor: archive old handbook docs, consolidate migration tracking, silent error handling`

## Recommended next task

Next session should start with:

### Phase D: hardening and merge readiness

Order:

1. keep smoke-checking the direct `bm.*` RPC surface after changes
2. expand regression coverage from compact RPC checks into higher-level UI or browser flows
3. harden production-facing access controls if deployment scope expands
4. document unlock procedure for locked sessions (admin-only via Supabase SQL Editor)
5. Phase 13: Database Security (RLS policies, SECURITY INVOKER review, auth checks)
6. Phase 14: Infrastructure Hardening (fetch timeouts, retry logic, runtime type validation)

Latest audit:

- [bm-write-flow-audit.md](bm-write-flow-audit.md)
- [CLEANCODE_BACKLOG.md](../../CLEANCODE_BACKLOG.md) — 139/151 items complete

## Session lock feature

### How it works

1. Host clicks "🔒 Lock session" in Actions dropdown
2. Confirmation dialog appears
3. On confirm, `publish_session` is called with `locked: true` in the snapshot
4. The session status is set to `'locked'` in the database
5. All interactive elements are disabled (checkboxes, scores, actions)
6. Any mutation attempt is rejected by the server (any non-draft status blocks writes)

### Important: locked must be set in session object

The server reads `p_snapshot->'session'->>'locked'` to set the `status` column. On subsequent writes, the server checks `bm.sessions.status <> 'draft'` (not the snapshot JSON) to enforce the lock. This means any non-draft status (locked, completed, archived) will block writes.

```typescript
// Correct: set locked in session object
await publishSession(sessionId, { 
  ...current, 
  session: { ...current.session, locked: true }
})
```

The `status` column is the source of truth for lock enforcement. The `locked` field in the snapshot is only used at write time to determine what `status` value to set.

### How to unlock (admin-only)

Unlock is intentionally NOT available in the UI. To unlock a session:

1. Open Supabase Dashboard → SQL Editor
2. Run:
   ```sql
   SELECT bm.unlock_session('<session-id>');
   ```
   Replace `<session-id>` with the actual session ID.

This sets the session status back to `'draft'`, bumps the version, and allows edits again. The function is restricted to `service_role` only (not exposed to `anon` or `authenticated`).

## If continuing in a new session

A new session should read these first:

1. [`docs/handbook/current-status.md`](current-status.md)
2. [`docs/handbook/archive/supabase-migration.md`](archive/supabase-migration.md)
3. [`docs/handbook/archive/persistence-migration-closure-2026-06-18.md`](archive/persistence-migration-closure-2026-06-18.md)
4. [`docs/handbook/roadmap.md`](roadmap.md)

That is enough context to resume efficiently.

## Historical Context

### Environment variable migration

The app originally used `VITE_APPS_SCRIPT_URL` to connect to a Google Apps Script backend. During the Supabase migration, this was replaced with:

- `VITE_SUPABASE_URL`
- `VITE_SUPABASE_KEY`

See [.env.local.example](../../.env.local.example) for the current contract.

### Google Sheets export limitations

The repository does not contain Google service account credentials, Sheets API credentials, or OAuth client setup. Automatic export of historical Google Sheets data is not possible from the repo alone. Old data can only be recovered through:

1. Manual spreadsheet export
2. A temporary one-off script using your Google access
3. A direct Apps Script/Sheet dump performed outside this repo

This is no longer a blocker for the local app runtime — it only matters if you need to recover older external history not already carried into the `bm`-based working set.
