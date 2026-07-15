# Concurrency & Parallelism Audit

Last updated: 2026-07-15

This document audits concurrency, parallelism, and scheduling efficiency across the codebase. Findings are grouped by implementation effort. Each item includes the affected file, current behavior, proposed fix, and estimated effort/impact.

## 1. Quick Wins

### 1.1 Overlay Images Sequential → Parallel

File: [src/pages/InstagramPostPage.tsx:377-392](/Users/user/Projects/badminton-match/src/pages/InstagramPostPage.tsx:377)

Current behavior:

- Five `loadImage()` calls are awaited sequentially in a `for`-less chain inside `loadOverlays()`.
- Each image blocks until the previous one finishes loading.

Fix:

- Wrap all five calls in `Promise.all()` and destructure the result.

Effort: 5 min. Impact: Low-Medium (cuts total load time to the slowest single image).

### 1.2 Unnecessary `['player']` Invalidation

File: [src/queries/sessions.ts:18-24](/Users/user/Projects/badminton-match/src/queries/sessions.ts:18)

Current behavior:

- `invalidateRelatedQueries` always invalidates three query prefixes: `['sessions']`, `['players']`, and `['player']`.
- Most mutations (toggle played, set score, swap) do not change player data.
- Invalidating `['player']` triggers N+1 refetches of individual player stat queries that are still fresh.

Fix:

- Only include `queryClient.invalidateQueries({ queryKey: ['player'] })` when the mutation actually changes player data (i.e., `useReplacePlayer`).
- Split into two helpers or accept a parameter flag.

Effort: 10 min. Impact: Medium.

### 1.3 `staleTime: 0` Causes Over-fetching

**Status: RESOLVED (2026-07-15)** — Changed to `staleTime: 30_000` in `main.tsx`

File: [src/main.tsx:10](/Users/user/Projects/badminton-match/src/main.tsx:10)

Current behavior:

- The global React Query default sets `staleTime: 0`.
- Every query is considered stale on every component mount, triggering an immediate background refetch even when data was fetched seconds ago.

Fix:

- Set `staleTime: 30_000` (30 s) as the global default.
- Override to `staleTime: 0` only on queries that truly need real-time freshness (e.g., `useGetSession` detail view).

Effort: 5 min. Impact: Medium (eliminates redundant network round-trips on navigation).

### 1.4 No Debounce on Rapid Mutations

File: [src/pages/GeneratePage.tsx:472-480](/Users/user/Projects/badminton-match/src/pages/GeneratePage.tsx:472)

Current behavior:

- `handleTogglePlayed` and `handleSetScore` call `publishToCloud` synchronously on every user action.
- Rapid toggles or score adjustments fire multiple concurrent `publishSession` RPC calls.
- These can race, causing version mismatch errors or redundant Supabase writes.

Fix:

- Debounce `publishToCloud` with a 300 ms trailing delay (e.g., `useMemo(() => debounce(publishToCloud, 300), [...])` or a ref-based debounce helper).
- Local state updates remain instant; only the cloud sync is deferred.

Effort: 30 min. Impact: Medium.

## 2. Medium Effort

### 2.1 Generator Blocks Main Thread

File: [src/pages/GeneratePage.tsx:568-589](/Users/user/Projects/badminton-match/src/pages/GeneratePage.tsx:568)

Current behavior:

- `handleRetryUntilGood` runs a synchronous `while` loop calling `generate()` up to 30 times.
- Each `generate()` call takes 5-20 ms, so the loop can block the main thread for 150-600 ms, freezing the UI.

Fix (simple):

- Yield to the browser between iterations using `requestAnimationFrame` or `setTimeout` wrapped in a promise. A ~5-line change converts the loop to an async function that yields each iteration.

Fix (full offload):

- Move `src/generator/index.ts` into a Web Worker. The generator is pure computation with no DOM access. Transfer cost is ~3 KB of player/config data.

Effort: 15 min (rAF yield) / 1 day (Worker). Impact: High (eliminates perceptible UI freeze).

### 2.2 Full-Snapshot Publish (No Delta)

File: [src/queries/endpoints.ts:74-76](/Users/user/Projects/badminton-match/src/queries/endpoints.ts:74)

Current behavior:

- Every mutation (toggle, score, swap, absent, replace) builds a full `CloudSnapshot` and sends the entire object (3-20 KB) via `publishSession`.
- The server performs last-write-wins replacement.

Fix:

- Introduce delta-based RPC using JSON Merge Patch or per-field mutation endpoints.
- Requires Supabase migration to add new RPC functions.

Effort: Days (requires backend migration). Impact: Medium (reduces payload size and enables finer-grained conflict detection).

### 2.3 Canvas Drawing on Main Thread

File: [src/pages/InstagramPostPage.tsx:394-399](/Users/user/Projects/badminton-match/src/pages/InstagramPostPage.tsx:394)

Current behavior:

- The `useEffect` that calls `drawCanvas` fires on every change to `photoOffset` and `photoZoom`.
- During drag interactions, this redraws the full canvas on every pointer pixel movement.

Fix:

- Throttle canvas redraws using `requestAnimationFrame` so at most one draw happens per frame (~16 ms).
- Use a ref to store the latest offset/zoom and draw from the rAF callback.

Effort: 1 hour. Impact: Low-Medium.

### 2.4 Dual Mutation Paths

Current behavior:

- `GeneratePage` uses `usePublishSession` for all mutations.
- `SharedSessionPage` uses individual hooks (`useTogglePlayed`, `useSetScore`, etc.) with their own optimistic update logic.
- The two paths duplicate snapshot-building and error-handling code.

Fix:

- Unify to a single mutation layer used by both pages.

Effort: 1 day. Impact: Medium (reduces maintenance surface and inconsistency risk).

### 2.5 No Mutation Queue

**Status: RESOLVED (2026-07-15)** — All session and tournament hooks now have `cancelQueries` in `onMutate`

Current behavior:

- Rapid mutations can race. If two `publishSession` calls overlap, the second may overwrite the first or trigger a version mismatch error.
- The current `refetchOnVersionMismatch` handler retries once but does not serialize the queue.

Fix (simple):

- Debounce publishes (covered in 1.4). This prevents most races in practice.

Fix (robust):

- Implement a serial mutation queue that processes one publish at a time and coalesces pending mutations.

Effort: 30 min (debounce) / 1 hour (queue). Impact: High (eliminates data loss from race conditions).

## 3. Hard / Architectural

### 3.1 Web Worker for Schedule Generation

File: [src/generator/index.ts](/Users/user/Projects/badminton-match/src/generator/index.ts) (447 lines, pure computation)

Current behavior:

- The entire generator runs on the main thread.
- Long retry loops (see 2.1) freeze the UI.

Future:

- Offload to a Web Worker. The generator has no DOM dependencies. Transfer cost is ~3 KB of player/config data; result is ~5-15 KB.

Effort: 1 day. Impact: High.

### 3.2 Incremental Updates Architecture

Current behavior:

- Full-snapshot last-write-wins semantics. Every mutation sends the entire session state.

Future:

- Individual table mutations with row-level locking.
- Requires Supabase migration: new per-field RPC functions, optimistic locking via version column, client-side conflict resolution.

Effort: 1 week (Supabase migration + client refactor). Impact: High (enables true multi-user editing).

### 3.3 PWA Offline Strategy

Current behavior:

- No runtime caching for API calls.
- No background sync for offline mutations.
- Offline mode is effectively non-functional for write operations.

Future:

- `workbox-background-sync` for mutation queue (replay queued writes when back online).
- `NetworkFirst` strategy for Supabase API calls with stale-while-revalidate fallback.
- IndexedDB mirror for session state.

Effort: 1 week. Impact: High (enables offline editing and reliable sync).

### 3.4 OffscreenCanvas for Exports

File: [src/pages/InstagramPostPage.tsx](/Users/user/Projects/badminton-match/src/pages/InstagramPostPage.tsx)

Current behavior:

- `canvas.toBlob()` blocks the main thread for 50-200 ms during image export.

Future:

- Use `OffscreenCanvas` in a Web Worker to perform the encoding off the main thread.

Effort: 1 day. Impact: Medium.

### 3.5 Component Re-render Optimization

Current behavior:

- `SummaryModal` has ~20 `useState` calls, causing frequent re-renders.
- `GeneratePage` has ~15 `useStore` selectors, each triggering re-renders on any store change.
- `InstagramPostPage` redraws the canvas on every pointer pixel during drag.

Future:

- `React.memo` on expensive child components.
- `useMemo` for derived data.
- `requestAnimationFrame` throttling for canvas redraws (see 2.3).
- Consolidate Zustand selectors with shallow equality.

Effort: 1 day. Impact: Medium.

## Top 3 Recommendations (by ROI)

| Rank | Fix | Effort | Impact |
|------|-----|--------|--------|
| 1 | Yield during retry loop (2.1) | 15 min | Eliminates UI freeze on generate |
| 2 | Debounce cloud publishes (1.4 / 2.5) | 30 min | Reduces version mismatch + Supabase writes |
| 3 | `staleTime: 30_000` (1.3) | 5 min | Eliminates redundant refetches on navigation |
