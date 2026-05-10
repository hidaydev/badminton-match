# Queries Layer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Consolidate all React Query hooks and raw fetch functions into `src/queries/`, removing `src/utils/cloudSync.ts` and making all 6 pages import only from `src/queries`.

**Architecture:** Create a `src/queries/` folder with `endpoints.ts` (raw fetch functions), `types.ts` (shared types), three domain hook files (`sessions.ts`, `players.ts`, `tournament.ts`), and a barrel `index.ts`. Pages drop their inline `useQuery`/`useMutation` calls and import named hooks. Optimistic-update cache logic moves into the hooks; per-mutate `onSuccess`/`onError` UI callbacks (e.g. `setSaveError`) stay in the components via React Query's second `mutate()` argument.

**Tech Stack:** React 19, TypeScript, @tanstack/react-query v5, Vite

---

### Task 1: Create the feature branch

**Files:**
- No file changes — git only

- [ ] **Step 1: Create and switch to branch**

```bash
git checkout -b refactor/queries-layer
```

Expected: `Switched to a new branch 'refactor/queries-layer'`

- [ ] **Step 2: Verify branch**

```bash
git branch --show-current
```

Expected: `refactor/queries-layer`

---

### Task 2: Create `src/queries/types.ts`

**Files:**
- Create: `src/queries/types.ts`

- [ ] **Step 1: Create the file with all shared types**

Create `src/queries/types.ts`:

```typescript
import type { SessionConfig, Player, FixMatch, ScheduleSlot, GameScore } from '../store'
export type { TournamentSnapshot } from '../utils/tournament'

export interface CloudSnapshot {
  session: SessionConfig
  players: Player[]
  fixMatches: FixMatch[]
  schedule: ScheduleSlot[]
  playedGames: string[]
  gameScores: Record<string, GameScore>
  absentPlayers?: string[]
}

export interface SessionMeta {
  id: string
  title: string
  date: string
  playerCount: number
  totalGames: number
}

export interface PlayerSummary {
  name: string
  gender: 'M' | 'F'
  tier: 1 | 2 | 3 | 4
}

export interface PlayerStats {
  name: string
  gamesPlayed: number
  wins: number
  losses: number
  pointsFor: number
  pointsAgainst: number
  sessions: { id: string; date: string; title: string; absent?: boolean }[]
  topPartners: { name: string; count: number; wins: number; losses: number }[]
  topOpponents: { name: string; count: number; wins: number; losses: number }[]
}
```

- [ ] **Step 2: Verify TypeScript accepts the file**

```bash
npx tsc --noEmit 2>&1 | grep "queries/types"
```

Expected: no output (no errors in this file)

---

### Task 3: Create `src/queries/endpoints.ts`

**Files:**
- Create: `src/queries/endpoints.ts`

All raw fetch functions move here from `src/utils/cloudSync.ts`. The `TOURNAMENT_ID` constant also moves here. The `scriptUrl()` helper stays private to this file.

- [ ] **Step 1: Create the file**

Create `src/queries/endpoints.ts`:

```typescript
import type { CloudSnapshot, SessionMeta, PlayerSummary, PlayerStats } from './types'
import type { TournamentSnapshot } from '../utils/tournament'

export const TOURNAMENT_ID = 'tournament-2026-05-23-majadu'

function scriptUrl(): string {
  const url = import.meta.env.VITE_APPS_SCRIPT_URL as string
  if (!url) throw new Error('VITE_APPS_SCRIPT_URL is not set')
  return url
}

export async function getSession(id: string): Promise<CloudSnapshot | null> {
  const res = await fetch(`${scriptUrl()}?id=${encodeURIComponent(id)}`)
  const json = await res.json() as { ok: boolean; data?: CloudSnapshot; error?: string }
  if (!json.ok) return null
  return json.data ?? null
}

export async function publishSession(id: string, data: CloudSnapshot): Promise<void> {
  const res = await fetch(scriptUrl(), {
    method: 'POST',
    // No Content-Type header: browser sends text/plain, avoiding CORS preflight.
    // Apps Script reads body via e.postData.contents.
    body: JSON.stringify({ id, data }),
  })
  const json = await res.json() as { ok: boolean; error?: string }
  if (!json.ok) throw new Error(json.error ?? 'publish failed')
}

export async function listSessions(): Promise<SessionMeta[]> {
  const res = await fetch(`${scriptUrl()}?action=list`)
  const json = await res.json() as { ok: boolean; data?: SessionMeta[]; error?: string }
  if (!json.ok) throw new Error(json.error ?? 'list failed')
  return json.data ?? []
}

export async function listPlayers(): Promise<PlayerSummary[]> {
  const res = await fetch(`${scriptUrl()}?action=players`)
  const json = await res.json() as { ok: boolean; data?: PlayerSummary[]; error?: string }
  if (!json.ok) throw new Error(json.error ?? 'list players failed')
  return json.data ?? []
}

export async function getPlayerStats(name: string): Promise<PlayerStats> {
  const res = await fetch(`${scriptUrl()}?action=playerStats&name=${encodeURIComponent(name)}`)
  const json = await res.json() as { ok: boolean; data?: PlayerStats; error?: string }
  if (!json.ok) throw new Error(json.error ?? 'player stats failed')
  if (!json.data) throw new Error('no data')
  return json.data
}

export async function getTournament(id: string): Promise<TournamentSnapshot | null> {
  const res = await fetch(`${scriptUrl()}?action=getTournament&id=${encodeURIComponent(id)}`)
  const json = await res.json() as { ok: boolean; data?: TournamentSnapshot; error?: string }
  if (!json.ok) return null
  return json.data ?? null
}

export async function publishTournament(id: string, data: TournamentSnapshot): Promise<void> {
  const res = await fetch(scriptUrl(), {
    method: 'POST',
    // No Content-Type header: browser sends text/plain, avoiding CORS preflight.
    // Apps Script reads body via e.postData.contents.
    body: JSON.stringify({ type: 'tournament', id, data }),
  })
  const json = await res.json() as { ok: boolean; error?: string }
  if (!json.ok) throw new Error(json.error ?? 'publish tournament failed')
}
```

- [ ] **Step 2: Verify TypeScript accepts the file**

```bash
npx tsc --noEmit 2>&1 | grep "queries/endpoints"
```

Expected: no output

---

### Task 4: Create `src/queries/players.ts`

**Files:**
- Create: `src/queries/players.ts`

- [ ] **Step 1: Create the file**

Create `src/queries/players.ts`:

```typescript
import { useQuery } from '@tanstack/react-query'
import { listPlayers, getPlayerStats } from './endpoints'
import type { PlayerSummary, PlayerStats } from './types'

export function useListPlayers() {
  return useQuery<PlayerSummary[]>({
    queryKey: ['players'],
    queryFn: listPlayers,
  })
}

export function useGetPlayerStats(name: string | undefined) {
  return useQuery<PlayerStats>({
    queryKey: ['player', name],
    queryFn: () => getPlayerStats(decodeURIComponent(name!)),
    enabled: !!name,
  })
}
```

- [ ] **Step 2: Verify TypeScript accepts the file**

```bash
npx tsc --noEmit 2>&1 | grep "queries/players"
```

Expected: no output

---

### Task 5: Create `src/queries/sessions.ts`

**Files:**
- Create: `src/queries/sessions.ts`

This file holds all session-related queries and mutations. The optimistic-update cache logic (cancel queries, set data, revert on error, invalidate on settled) lives in the hooks. UI callbacks (`setSaveError`) are NOT in the hooks — they are passed by components as the second argument to `mutation.mutate(vars, { onSuccess, onError })`.

- [ ] **Step 1: Create the file**

Create `src/queries/sessions.ts`:

```typescript
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import { getSession, publishSession, listSessions } from './endpoints'
import type { CloudSnapshot, SessionMeta } from './types'
import { applySwap, type SwapTarget } from '../utils/swap'

export function useListSessions() {
  return useQuery<SessionMeta[]>({
    queryKey: ['sessions'],
    queryFn: listSessions,
  })
}

export function useGetSession(sessionId: string | undefined) {
  return useQuery<CloudSnapshot | null>({
    queryKey: ['session', sessionId],
    queryFn: () => getSession(sessionId!),
    enabled: !!sessionId,
  })
}

export function usePublishSession(sessionId: string | undefined) {
  const queryClient = useQueryClient()
  return useMutation({
    mutationFn: (snap: CloudSnapshot) => publishSession(sessionId!, snap),
    onSuccess: (_data, snap) => {
      queryClient.setQueryData(['session', sessionId], snap)
    },
  })
}

export function useTogglePlayed(sessionId: string) {
  const queryClient = useQueryClient()
  return useMutation({
    mutationFn: async ({ nextPlayed }: { key: string; nextPlayed: string[] }) => {
      const current = queryClient.getQueryData<CloudSnapshot>(['session', sessionId])
      if (!current) throw new Error('no data')
      const updated: CloudSnapshot = { ...current, playedGames: nextPlayed }
      await publishSession(sessionId, updated)
      return updated
    },
    onMutate: async ({ nextPlayed }) => {
      await queryClient.cancelQueries({ queryKey: ['session', sessionId] })
      const previous = queryClient.getQueryData<CloudSnapshot>(['session', sessionId])
      queryClient.setQueryData<CloudSnapshot | null>(['session', sessionId], (old) => {
        if (!old) return old
        return { ...old, playedGames: nextPlayed }
      })
      return { previous }
    },
    onError: (_err, _vars, context) => {
      queryClient.setQueryData(['session', sessionId], context?.previous)
    },
    onSettled: () => {
      queryClient.invalidateQueries({ queryKey: ['session', sessionId] })
    },
  })
}

export function useSetScore(sessionId: string) {
  const queryClient = useQueryClient()
  return useMutation({
    mutationFn: async ({ key, a, b }: { key: string; a: number; b: number }) => {
      const current = queryClient.getQueryData<CloudSnapshot>(['session', sessionId])
      if (!current) throw new Error('no data')
      const nextScores = { ...current.gameScores, [key]: { a, b } }
      const nextPlayed = current.playedGames.includes(key)
        ? current.playedGames
        : [...current.playedGames, key]
      const updated: CloudSnapshot = { ...current, gameScores: nextScores, playedGames: nextPlayed }
      await publishSession(sessionId, updated)
      return updated
    },
    onMutate: async ({ key, a, b }) => {
      await queryClient.cancelQueries({ queryKey: ['session', sessionId] })
      const previous = queryClient.getQueryData<CloudSnapshot>(['session', sessionId])
      queryClient.setQueryData<CloudSnapshot | null>(['session', sessionId], (old) => {
        if (!old) return old
        const nextScores = { ...old.gameScores, [key]: { a, b } }
        const nextPlayed = old.playedGames.includes(key)
          ? old.playedGames
          : [...old.playedGames, key]
        return { ...old, gameScores: nextScores, playedGames: nextPlayed }
      })
      return { previous }
    },
    onError: (_err, _vars, context) => {
      queryClient.setQueryData(['session', sessionId], context?.previous)
    },
    onSettled: () => {
      queryClient.invalidateQueries({ queryKey: ['session', sessionId] })
    },
  })
}

export function useSwapPlayers(sessionId: string) {
  const queryClient = useQueryClient()
  return useMutation({
    mutationFn: async ({ t1, t2 }: { t1: SwapTarget; t2: SwapTarget }) => {
      const current = queryClient.getQueryData<CloudSnapshot>(['session', sessionId])
      if (!current) throw new Error('no data')
      const nextSchedule = applySwap(current.schedule, t1, t2)
      const updated: CloudSnapshot = { ...current, schedule: nextSchedule }
      await publishSession(sessionId, updated)
      return updated
    },
    onMutate: async ({ t1, t2 }) => {
      await queryClient.cancelQueries({ queryKey: ['session', sessionId] })
      const previous = queryClient.getQueryData<CloudSnapshot>(['session', sessionId])
      queryClient.setQueryData<CloudSnapshot | null>(['session', sessionId], (old) => {
        if (!old) return old
        return { ...old, schedule: applySwap(old.schedule, t1, t2) }
      })
      return { previous }
    },
    onError: (_err, _vars, context) => {
      queryClient.setQueryData(['session', sessionId], context?.previous)
    },
    onSettled: () => {
      queryClient.invalidateQueries({ queryKey: ['session', sessionId] })
    },
  })
}

export function useSetAbsent(sessionId: string) {
  const queryClient = useQueryClient()
  return useMutation({
    mutationFn: async ({ nextAbsent }: { nextAbsent: string[] }) => {
      const current = queryClient.getQueryData<CloudSnapshot>(['session', sessionId])
      if (!current) throw new Error('no data')
      const updated: CloudSnapshot = { ...current, absentPlayers: nextAbsent }
      await publishSession(sessionId, updated)
      return updated
    },
    onMutate: async ({ nextAbsent }) => {
      await queryClient.cancelQueries({ queryKey: ['session', sessionId] })
      const previous = queryClient.getQueryData<CloudSnapshot>(['session', sessionId])
      queryClient.setQueryData<CloudSnapshot | null>(['session', sessionId], (old) => {
        if (!old) return old
        return { ...old, absentPlayers: nextAbsent }
      })
      return { previous }
    },
    onError: (_err, _vars, context) => {
      queryClient.setQueryData(['session', sessionId], context?.previous)
    },
    onSettled: () => {
      queryClient.invalidateQueries({ queryKey: ['session', sessionId] })
    },
  })
}
```

- [ ] **Step 2: Verify TypeScript accepts the file**

```bash
npx tsc --noEmit 2>&1 | grep "queries/sessions"
```

Expected: no output

---

### Task 6: Create `src/queries/tournament.ts`

**Files:**
- Create: `src/queries/tournament.ts`

Same pattern as sessions: hooks own cache logic, components pass UI callbacks via `mutate(vars, { onSuccess, onError })`.

- [ ] **Step 1: Create the file**

Create `src/queries/tournament.ts`:

```typescript
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import { getTournament, publishTournament, TOURNAMENT_ID } from './endpoints'
import type { TournamentSnapshot } from './types'
import type { GroupId, TournamentPair } from '../utils/tournament'
import {
  generateGroupMatches,
  initKnockoutMatches,
  propagateBracket,
} from '../utils/tournament'

const GROUP_IDS: GroupId[] = ['A', 'B', 'C', 'D']

export function useGetTournament() {
  return useQuery<TournamentSnapshot | null>({
    queryKey: ['tournament', TOURNAMENT_ID],
    queryFn: () => getTournament(TOURNAMENT_ID),
    staleTime: 1000 * 60,
    refetchOnWindowFocus: true,
  })
}

export function useConfirmGroups() {
  const queryClient = useQueryClient()
  return useMutation({
    mutationFn: async ({
      localGroups,
      name,
      date,
      pairs,
    }: {
      localGroups: Record<GroupId, string[]>
      name: string
      date: string
      pairs: TournamentPair[]
    }) => {
      const groupMatches = GROUP_IDS.flatMap((g) => generateGroupMatches(g, localGroups[g]))
      const allMatches = [...groupMatches, ...initKnockoutMatches()]
      const newMatches = propagateBracket(allMatches, localGroups, pairs)
      await publishTournament(TOURNAMENT_ID, { name, date, pairs, groups: localGroups, matches: newMatches })
    },
    onMutate: async () => {
      await queryClient.cancelQueries({ queryKey: ['tournament', TOURNAMENT_ID] })
    },
    onSettled: () => queryClient.invalidateQueries({ queryKey: ['tournament', TOURNAMENT_ID] }),
  })
}

export function useSetTournamentScore() {
  const queryClient = useQueryClient()
  return useMutation({
    mutationFn: async (_: { matchId: string; scoreA: number; scoreB: number }) => {
      const current = queryClient.getQueryData<TournamentSnapshot | null>(['tournament', TOURNAMENT_ID])
      if (!current) return
      await publishTournament(TOURNAMENT_ID, current)
    },
    onMutate: async ({ matchId, scoreA, scoreB }: { matchId: string; scoreA: number; scoreB: number }) => {
      await queryClient.cancelQueries({ queryKey: ['tournament', TOURNAMENT_ID] })
      const previous = queryClient.getQueryData<TournamentSnapshot | null>(['tournament', TOURNAMENT_ID])
      if (previous) {
        const updated = previous.matches.map((m) =>
          m.id === matchId ? { ...m, scoreA, scoreB } : m
        )
        const propagated = propagateBracket(updated, previous.groups, previous.pairs)
        queryClient.setQueryData(['tournament', TOURNAMENT_ID], { ...previous, matches: propagated })
      }
      return { previous }
    },
    onError: (_err, _vars, context) => {
      queryClient.setQueryData(['tournament', TOURNAMENT_ID], context?.previous)
    },
    onSettled: () => queryClient.invalidateQueries({ queryKey: ['tournament', TOURNAMENT_ID] }),
  })
}

export function useResetTournament() {
  const queryClient = useQueryClient()
  return useMutation({
    mutationFn: async ({
      name,
      date,
      pairs,
    }: {
      name: string
      date: string
      pairs: TournamentPair[]
    }) => {
      await publishTournament(TOURNAMENT_ID, {
        name,
        date,
        pairs,
        groups: { A: [], B: [], C: [], D: [] },
        matches: [],
      })
    },
    onMutate: async () => {
      await queryClient.cancelQueries({ queryKey: ['tournament', TOURNAMENT_ID] })
    },
    onSettled: () => queryClient.invalidateQueries({ queryKey: ['tournament', TOURNAMENT_ID] }),
  })
}
```

- [ ] **Step 2: Verify TypeScript accepts the file**

```bash
npx tsc --noEmit 2>&1 | grep "queries/tournament"
```

Expected: no output

---

### Task 7: Create `src/queries/index.ts`

**Files:**
- Create: `src/queries/index.ts`

Note: `endpoints.ts` raw fetch functions are intentionally NOT re-exported — they are internal to the queries layer. Pages must not call them directly.

- [ ] **Step 1: Create the barrel export**

Create `src/queries/index.ts`:

```typescript
export * from './types'
export * from './players'
export * from './sessions'
export * from './tournament'
```

- [ ] **Step 2: Verify TypeScript compiles the full queries folder**

```bash
npx tsc --noEmit 2>&1 | grep "src/queries"
```

Expected: no output

- [ ] **Step 3: Commit the queries layer**

```bash
git add src/queries/
git commit -m "feat: add src/queries layer with domain hooks and endpoints"
```

---

### Task 8: Update `src/pages/SessionListPage.tsx`

**Files:**
- Modify: `src/pages/SessionListPage.tsx`

- [ ] **Step 1: Replace the import block**

Find this at the top of the file:

```typescript
import { useQuery } from '@tanstack/react-query'
import { listSessions, type SessionMeta } from '../utils/cloudSync'
```

Replace with:

```typescript
import { useListSessions, type SessionMeta } from '../queries'
```

- [ ] **Step 2: Replace the inline query with the hook**

Find:

```typescript
  const { data: sessions = [], isLoading, isError } = useQuery<SessionMeta[]>({
    queryKey: ['sessions'],
    queryFn: listSessions,
  })
```

Replace with:

```typescript
  const { data: sessions = [], isLoading, isError } = useListSessions()
```

- [ ] **Step 3: Verify TypeScript**

```bash
npx tsc --noEmit 2>&1 | grep "SessionListPage"
```

Expected: no output

---

### Task 9: Update `src/pages/PlayerHistoryPage.tsx`

**Files:**
- Modify: `src/pages/PlayerHistoryPage.tsx`

- [ ] **Step 1: Replace the import block**

Find:

```typescript
import { useQuery } from '@tanstack/react-query'
import { listPlayers, type PlayerSummary } from '../utils/cloudSync'
```

Replace with:

```typescript
import { useListPlayers, type PlayerSummary } from '../queries'
```

- [ ] **Step 2: Replace the inline query**

Find:

```typescript
  const { data: players = [], isLoading, isError } = useQuery<PlayerSummary[]>({
    queryKey: ['players'],
    queryFn: listPlayers,
  })
```

Replace with:

```typescript
  const { data: players = [], isLoading, isError } = useListPlayers()
```

- [ ] **Step 3: Verify TypeScript**

```bash
npx tsc --noEmit 2>&1 | grep "PlayerHistoryPage"
```

Expected: no output

---

### Task 10: Update `src/pages/PlayerDetailPage.tsx`

**Files:**
- Modify: `src/pages/PlayerDetailPage.tsx`

- [ ] **Step 1: Replace the import block**

Find:

```typescript
import { useQuery } from '@tanstack/react-query'
import { getPlayerStats, type PlayerStats } from '../utils/cloudSync'
```

Replace with:

```typescript
import { useGetPlayerStats, type PlayerStats } from '../queries'
```

- [ ] **Step 2: Replace the inline query**

Find:

```typescript
  const { data: stats, isLoading, isError } = useQuery<PlayerStats>({
    queryKey: ['player', name],
    queryFn: () => getPlayerStats(decodeURIComponent(name!)),
    enabled: !!name,
  })
```

Replace with:

```typescript
  const { data: stats, isLoading, isError } = useGetPlayerStats(name)
```

Note: `useGetPlayerStats` already calls `decodeURIComponent` internally and has `enabled: !!name`.

- [ ] **Step 3: Verify TypeScript**

```bash
npx tsc --noEmit 2>&1 | grep "PlayerDetailPage"
```

Expected: no output

---

### Task 11: Update `src/pages/GeneratePage.tsx`

**Files:**
- Modify: `src/pages/GeneratePage.tsx`

- [ ] **Step 1: Replace the cloudSync import**

Find:

```typescript
import { publishSession, type CloudSnapshot } from '../utils/cloudSync'
import { useMutation, useQueryClient } from '@tanstack/react-query'
```

Replace with:

```typescript
import { usePublishSession, type CloudSnapshot } from '../queries'
```

- [ ] **Step 2: Replace the inline mutation**

Find (around line 409–423):

```typescript
  const queryClient = useQueryClient()
  // ...
  const publish = useMutation({
    mutationFn: (snap: CloudSnapshot) => publishSession(cloudSessionId!, snap),
    onSuccess: (_data, snap) => {
      queryClient.setQueryData(['session', cloudSessionId], snap)
    },
    onError: () => { /* silent — organizer flow, no UI feedback needed */ },
  })
```

Replace with:

```typescript
  const publish = usePublishSession(cloudSessionId)
```

Note: Remove the `const queryClient = useQueryClient()` line too if it is now unused (check if `queryClient` is used anywhere else in the file before removing).

- [ ] **Step 3: Verify TypeScript**

```bash
npx tsc --noEmit 2>&1 | grep "GeneratePage"
```

Expected: no output

---

### Task 12: Update `src/pages/SharedSessionPage.tsx`

**Files:**
- Modify: `src/pages/SharedSessionPage.tsx`

This is the largest change. The 4 inline mutations are replaced with 4 hooks. The `onSuccess`/`onError` UI callbacks (`setSaveError`) move to the call sites via `mutate(vars, { onSuccess, onError })`.

- [ ] **Step 1: Replace the import block**

Find:

```typescript
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import { getSession, publishSession, type CloudSnapshot } from '../utils/cloudSync'
import { applySwap, type SwapTarget } from '../utils/swap'
```

Replace with:

```typescript
import { useQueryClient } from '@tanstack/react-query'
import {
  useGetSession,
  useTogglePlayed,
  useSetScore,
  useSwapPlayers,
  useSetAbsent,
  type CloudSnapshot,
} from '../queries'
```

Note: `applySwap` and `SwapTarget` are no longer imported in the component — they moved into the `useSwapPlayers` hook. Remove the entire `../utils/swap` import line.

Note: `useQueryClient` is still needed for the `onTogglePlayedGame` handler that reads current cache to compute `nextPlayed`.

- [ ] **Step 2: Replace the inline query and 4 mutations**

Find the block starting at line 15 and ending at line 136 (the `useQuery` + all 4 `useMutation` calls):

```typescript
  const { data: snapshot, isLoading, isError } = useQuery<CloudSnapshot | null>({
    queryKey: ['session', sessionId],
    queryFn: () => getSession(sessionId!),
    enabled: !!sessionId,
  })

  const togglePlayed = useMutation({
    mutationFn: async ({ nextPlayed }: { key: string; nextPlayed: string[] }) => {
      // ...
    },
    onMutate: async ({ key: _key, nextPlayed }) => {
      // ...
    },
    onSuccess: () => setSaveError(null),
    onError: (_err, _vars, context) => {
      queryClient.setQueryData(['session', sessionId], context?.previous)
      setSaveError('Failed to save, please try again')
    },
    onSettled: () => {
      queryClient.invalidateQueries({ queryKey: ['session', sessionId] })
    },
  })

  const setScore = useMutation({
    // ... (lines 48–81)
  })

  const swapPlayers = useMutation({
    // ... (lines 83–109)
  })

  const setAbsent = useMutation({
    // ... (lines 111–136)
  })
```

Replace the entire block with:

```typescript
  const { data: snapshot, isLoading, isError } = useGetSession(sessionId)
  const togglePlayed = useTogglePlayed(sessionId!)
  const setScore = useSetScore(sessionId!)
  const swapPlayers = useSwapPlayers(sessionId!)
  const setAbsent = useSetAbsent(sessionId!)
```

- [ ] **Step 3: Add `onSuccess`/`onError` callbacks at each call site**

Find the `onTogglePlayedGame` prop in the `SummaryModal`:

```typescript
        onTogglePlayedGame={(key) => {
          const current = queryClient.getQueryData<CloudSnapshot>(['session', sessionId])
          const nextPlayed = current?.playedGames.includes(key)
            ? current.playedGames.filter((k) => k !== key)
            : [...(current?.playedGames ?? []), key]
          togglePlayed.mutate({ key, nextPlayed })
        }}
```

Replace with:

```typescript
        onTogglePlayedGame={(key) => {
          const current = queryClient.getQueryData<CloudSnapshot>(['session', sessionId])
          const nextPlayed = current?.playedGames.includes(key)
            ? current.playedGames.filter((k) => k !== key)
            : [...(current?.playedGames ?? []), key]
          togglePlayed.mutate({ key, nextPlayed }, {
            onSuccess: () => setSaveError(null),
            onError: () => setSaveError('Failed to save, please try again'),
          })
        }}
```

Find the `onSetGameScore` prop:

```typescript
        onSetGameScore={(key, a, b) => setScore.mutate({ key, a, b })}
```

Replace with:

```typescript
        onSetGameScore={(key, a, b) => setScore.mutate({ key, a, b }, {
          onSuccess: () => setSaveError(null),
          onError: () => setSaveError('Failed to save, please try again'),
        })}
```

Find the `onSwapPlayers` prop:

```typescript
        onSwapPlayers={(t1, t2) => swapPlayers.mutate({ t1, t2 })}
```

Replace with:

```typescript
        onSwapPlayers={(t1, t2) => swapPlayers.mutate({ t1, t2 }, {
          onSuccess: () => setSaveError(null),
          onError: () => setSaveError('Failed to save, please try again'),
        })}
```

Find the `onSetAbsent` prop:

```typescript
        onSetAbsent={(nextAbsent) => setAbsent.mutate({ nextAbsent })}
```

Replace with:

```typescript
        onSetAbsent={(nextAbsent) => setAbsent.mutate({ nextAbsent }, {
          onSuccess: () => setSaveError(null),
          onError: () => setSaveError('Failed to save, please try again'),
        })}
```

- [ ] **Step 4: Verify TypeScript**

```bash
npx tsc --noEmit 2>&1 | grep "SharedSessionPage"
```

Expected: no output

---

### Task 13: Update `src/pages/TournamentPage.tsx`

**Files:**
- Modify: `src/pages/TournamentPage.tsx`

The 3 inline mutations (`confirmMutation`, `setScoreMutation`, `resetMutation`) are replaced with 3 hooks. Component-level UI callbacks (`setSaveError`, `setLocalGroups`) move to call sites.

- [ ] **Step 1: Replace the import block**

Find:

```typescript
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import {
  getTournament,
  publishTournament,
  TOURNAMENT_ID,
  type TournamentSnapshot,
} from '../utils/cloudSync'
```

Replace with:

```typescript
import { useQueryClient } from '@tanstack/react-query'
import {
  useGetTournament,
  useConfirmGroups,
  useSetTournamentScore,
  useResetTournament,
  type TournamentSnapshot,
} from '../queries'
```

- [ ] **Step 2: Replace the inline query and 3 mutations**

Find the query (lines 85–90):

```typescript
  const { data: snapshot, isFetching } = useQuery<TournamentSnapshot | null>({
    queryKey: ['tournament', TOURNAMENT_ID],
    queryFn: () => getTournament(TOURNAMENT_ID),
    staleTime: 1000 * 60,
    refetchOnWindowFocus: true,
  })
```

Replace with:

```typescript
  const { data: snapshot, isFetching } = useGetTournament()
```

Find `confirmMutation` (lines 111–124):

```typescript
  const confirmMutation = useMutation({
    onMutate: async () => {
      await queryClient.cancelQueries({ queryKey: ['tournament', TOURNAMENT_ID] })
    },
    mutationFn: async () => {
      const groupMatches = GROUP_IDS.flatMap((g) => generateGroupMatches(g, localGroups[g]))
      const allMatches = [...groupMatches, ...initKnockoutMatches()]
      const newMatches = propagateBracket(allMatches, localGroups, pairs)
      await publishTournament(TOURNAMENT_ID, { name, date, pairs, groups: localGroups, matches: newMatches })
    },
    onSuccess: () => setSaveError(null),
    onError: () => setSaveError('Failed to save groups, please try again'),
    onSettled: () => queryClient.invalidateQueries({ queryKey: ['tournament', TOURNAMENT_ID] }),
  })
```

Replace with:

```typescript
  const confirmMutation = useConfirmGroups()
```

Find `setScoreMutation` (lines 126–148):

```typescript
  const setScoreMutation = useMutation({
    onMutate: async ({ matchId, scoreA, scoreB }: { matchId: string; scoreA: number; scoreB: number }) => {
      await queryClient.cancelQueries({ queryKey: ['tournament', TOURNAMENT_ID] })
      const previous = queryClient.getQueryData<TournamentSnapshot | null>(['tournament', TOURNAMENT_ID])
      if (previous) {
        const updated = previous.matches.map((m) => m.id === matchId ? { ...m, scoreA, scoreB } : m)
        const propagated = propagateBracket(updated, previous.groups, previous.pairs)
        queryClient.setQueryData(['tournament', TOURNAMENT_ID], { ...previous, matches: propagated })
      }
      return { previous }
    },
    mutationFn: async (_: { matchId: string; scoreA: number; scoreB: number }) => {
      const current = queryClient.getQueryData<TournamentSnapshot | null>(['tournament', TOURNAMENT_ID])
      if (!current) return
      await publishTournament(TOURNAMENT_ID, current)
    },
    onSuccess: () => setSaveError(null),
    onError: (_err, _vars, context) => {
      queryClient.setQueryData(['tournament', TOURNAMENT_ID], context?.previous)
      setSaveError('Failed to save score, please try again')
    },
    onSettled: () => queryClient.invalidateQueries({ queryKey: ['tournament', TOURNAMENT_ID] }),
  })
```

Replace with:

```typescript
  const setScoreMutation = useSetTournamentScore()
```

Find `resetMutation` (lines 150–163):

```typescript
  const resetMutation = useMutation({
    onMutate: async () => {
      await queryClient.cancelQueries({ queryKey: ['tournament', TOURNAMENT_ID] })
    },
    mutationFn: async () => {
      await publishTournament(TOURNAMENT_ID, { name, date, pairs, groups: EMPTY_GROUPS, matches: [] })
    },
    onSuccess: () => {
      setSaveError(null)
      setLocalGroups(EMPTY_GROUPS)
    },
    onError: () => setSaveError('Failed to reset, please try again'),
    onSettled: () => queryClient.invalidateQueries({ queryKey: ['tournament', TOURNAMENT_ID] }),
  })
```

Replace with:

```typescript
  const resetMutation = useResetTournament()
```

- [ ] **Step 3: Update all mutation call sites to pass UI callbacks and required vars**

Find the confirm call site (look for `confirmMutation.mutate`). It will look like:

```typescript
confirmMutation.mutate()
```

or similar. Replace with:

```typescript
confirmMutation.mutate({ localGroups, name, date, pairs }, {
  onSuccess: () => setSaveError(null),
  onError: () => setSaveError('Failed to save groups, please try again'),
})
```

Find the score mutation call site (look for `setScoreMutation.mutate`):

```typescript
setScoreMutation.mutate({ matchId, scoreA, scoreB })
```

Replace with:

```typescript
setScoreMutation.mutate({ matchId, scoreA, scoreB }, {
  onSuccess: () => setSaveError(null),
  onError: () => setSaveError('Failed to save score, please try again'),
})
```

Find the reset mutation call site (look for `resetMutation.mutate`):

```typescript
resetMutation.mutate()
```

Replace with:

```typescript
resetMutation.mutate({ name, date, pairs }, {
  onSuccess: () => {
    setSaveError(null)
    setLocalGroups(EMPTY_GROUPS)
  },
  onError: () => setSaveError('Failed to reset, please try again'),
})
```

- [ ] **Step 4: Remove now-unused imports from `../utils/tournament`**

After replacing the mutations, `TOURNAMENT_ID` is no longer needed from `../utils/cloudSync` (already replaced). Also check whether `generateGroupMatches`, `initKnockoutMatches`, `propagateBracket` are still imported from `../utils/tournament` — they are no longer called in the component (they moved to the hook). Remove them from the import if unused.

The imports that should STAY (still used in the component for local logic and types):

```typescript
import type { GroupId, TournamentPair } from '../utils/tournament'
```

Remove from the `../utils/tournament` import:

```typescript
import {
  generateGroupMatches,
  initKnockoutMatches,
  propagateBracket,
} from '../utils/tournament'
```

- [ ] **Step 5: Remove now-unused `queryClient` if no longer needed**

After the changes, `queryClient` is used in two places in TournamentPage:
- `handleOpenModal`: `queryClient.invalidateQueries({ queryKey: ['tournament', TOURNAMENT_ID] })`
- `handleTabChange`: `queryClient.invalidateQueries({ queryKey: ['tournament', TOURNAMENT_ID] })`

Both still need `queryClient`. However `TOURNAMENT_ID` is now only needed in these two remaining `queryClient` calls. Import it from `../queries`:

In the `../queries` import, add `TOURNAMENT_ID` is NOT re-exported from `index.ts` (endpoints internals are not exposed). Instead, add a `TOURNAMENT_ID` export to `src/queries/index.ts` by re-exporting it from `endpoints.ts`:

Open `src/queries/index.ts` and add:

```typescript
export { TOURNAMENT_ID } from './endpoints'
```

Then in `TournamentPage.tsx`, add `TOURNAMENT_ID` to the `../queries` import:

```typescript
import {
  useGetTournament,
  useConfirmGroups,
  useSetTournamentScore,
  useResetTournament,
  TOURNAMENT_ID,
  type TournamentSnapshot,
} from '../queries'
```

- [ ] **Step 6: Verify TypeScript**

```bash
npx tsc --noEmit 2>&1 | grep "TournamentPage"
```

Expected: no output

---

### Task 14: Delete `src/utils/cloudSync.ts` and do final TypeScript check

**Files:**
- Delete: `src/utils/cloudSync.ts`

- [ ] **Step 1: Delete cloudSync.ts**

```bash
rm src/utils/cloudSync.ts
```

- [ ] **Step 2: Full TypeScript check — must be clean**

```bash
npx tsc --noEmit
```

Expected: no output (zero errors). If there are errors, fix them before proceeding.

- [ ] **Step 3: Verify no file still imports from cloudSync**

```bash
grep -r "cloudSync" src/
```

Expected: no output

---

### Task 15: Final commit

- [ ] **Step 1: Stage all changes**

```bash
git add src/pages/SessionListPage.tsx \
        src/pages/PlayerHistoryPage.tsx \
        src/pages/PlayerDetailPage.tsx \
        src/pages/GeneratePage.tsx \
        src/pages/SharedSessionPage.tsx \
        src/pages/TournamentPage.tsx \
        src/queries/index.ts
git rm src/utils/cloudSync.ts
```

- [ ] **Step 2: Commit**

```bash
git commit -m "refactor: migrate all pages to use src/queries layer, remove cloudSync.ts"
```

- [ ] **Step 3: Verify git log**

```bash
git log --oneline -3
```

Expected: two commits on this branch — the queries layer creation and the page migration.
