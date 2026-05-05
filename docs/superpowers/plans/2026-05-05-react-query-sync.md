# React Query Sync Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace all manual `useEffect`/`useState` fetch patterns with React Query, and add optimistic-update mutations to `SharedSessionPage` to fix the last-write-wins data loss bug.

**Architecture:** Install `@tanstack/react-query` and wrap the app in `QueryClientProvider`. Each cloud-fetching page gets a `useQuery` hook. `SharedSessionPage` gets two `useMutation` hooks (togglePlayed, setScore) with optimistic cache updates, rollback on error, and `invalidateQueries` on settle. `GeneratePage` gets a simple `useMutation` wrapping `publishSession`.

**Tech Stack:** React 19, @tanstack/react-query v5, TypeScript, Google Apps Script backend via `cloudSync.ts`

---

## File Map

| File | Change |
|---|---|
| `package.json` | Add `@tanstack/react-query` |
| `src/main.tsx` | Wrap app in `QueryClientProvider` |
| `src/pages/SessionListPage.tsx` | Replace `useEffect`/`useState` with `useQuery` |
| `src/pages/PlayerHistoryPage.tsx` | Replace `useEffect`/`useState` with `useQuery` |
| `src/pages/PlayerDetailPage.tsx` | Replace `useEffect`/`useState` with `useQuery` |
| `src/components/SummaryModal.tsx` | Add optional `saving` prop to disable checkbox + Save button |
| `src/pages/SharedSessionPage.tsx` | Full rewrite: `useQuery` + two `useMutation` hooks |
| `src/pages/GeneratePage.tsx` | Wrap `publishSession` calls in `useMutation` |

---

## Task 1: Install React Query and set up QueryClientProvider

**Files:**
- Modify: `package.json`
- Modify: `src/main.tsx`

- [ ] **Step 1: Install the package**

```bash
npm install @tanstack/react-query
```

Expected: package added to `node_modules`, `package.json` dependencies updated.

- [ ] **Step 2: Update `src/main.tsx`**

Replace the entire file with:

```tsx
import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import './index.css'
import App from './App.tsx'

const queryClient = new QueryClient({
  defaultOptions: {
    queries: {
      staleTime: 0,
      retry: 1,
    },
  },
})

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <QueryClientProvider client={queryClient}>
      <App />
    </QueryClientProvider>
  </StrictMode>,
)
```

- [ ] **Step 3: Verify the app still runs**

```bash
npm run dev
```

Expected: dev server starts, no TypeScript errors in the terminal.

- [ ] **Step 4: Commit**

```bash
git add package.json package-lock.json src/main.tsx
git commit -m "feat: install react-query and set up QueryClientProvider"
```

---

## Task 2: Replace SessionListPage with useQuery

**Files:**
- Modify: `src/pages/SessionListPage.tsx`

- [ ] **Step 1: Rewrite `SessionListPage.tsx`**

Replace the entire file with:

```tsx
import { useState } from 'react'
import { useQuery } from '@tanstack/react-query'
import { listSessions, type SessionMeta } from '../utils/cloudSync'

export default function SessionListPage() {
  const [dateFilter, setDateFilter] = useState('')

  const { data: sessions = [], isLoading, isError } = useQuery<SessionMeta[]>({
    queryKey: ['sessions'],
    queryFn: listSessions,
  })

  if (isLoading) return <p className="text-slate-400 text-sm">Loading sessions…</p>
  if (isError) return <p className="text-red-400 text-sm">Failed to load sessions.</p>

  const filtered = dateFilter ? sessions.filter((s) => s.date === dateFilter) : sessions

  return (
    <div className="flex flex-col gap-3">
      <h2 className="text-lg font-bold text-white">Sessions</h2>

      <div className="flex items-center gap-2">
        <input
          type="date"
          value={dateFilter}
          onChange={(e) => setDateFilter(e.target.value)}
          className="flex-1 bg-slate-900 border border-slate-800 rounded-lg px-3 py-2 text-xs font-mono text-slate-300 [color-scheme:dark]"
        />
        {dateFilter && (
          <button
            onClick={() => setDateFilter('')}
            className="text-xs text-slate-500 hover:text-slate-300 border border-slate-800 rounded-lg px-3 py-2 transition-colors"
          >
            Clear
          </button>
        )}
      </div>

      <p className="text-xs font-mono text-slate-500">
        <span className="text-indigo-400">{filtered.length}</span> session{filtered.length !== 1 ? 's' : ''}
      </p>

      {filtered.length === 0 && (
        <p className="text-slate-600 text-xs font-mono text-center py-8">No sessions on this date.</p>
      )}

      {filtered.map((s) => (
        <a
          key={s.id}
          href={`/s/${s.id}`}
          className="block bg-slate-900 border border-slate-800 rounded-xl p-4 hover:border-slate-600 transition-colors"
        >
          <div className="flex items-start justify-between gap-2">
            <div>
              <p className="text-sm font-semibold text-white">{s.title || 'Untitled Session'}</p>
              <p className="text-xs text-slate-400 mt-0.5 font-mono">{s.date.split('-').reverse().join('-')}</p>
            </div>
            <div className="text-right shrink-0">
              <p className="text-xs text-slate-400">{s.playerCount} players</p>
              <p className="text-xs text-slate-500">{s.totalGames} games</p>
            </div>
          </div>
        </a>
      ))}
    </div>
  )
}
```

- [ ] **Step 2: Verify no TypeScript errors**

```bash
npm run build
```

Expected: build succeeds with no errors.

- [ ] **Step 3: Commit**

```bash
git add src/pages/SessionListPage.tsx
git commit -m "feat: migrate SessionListPage to useQuery"
```

---

## Task 3: Replace PlayerHistoryPage with useQuery

**Files:**
- Modify: `src/pages/PlayerHistoryPage.tsx`

- [ ] **Step 1: Rewrite `PlayerHistoryPage.tsx`**

Replace the entire file with:

```tsx
import { useNavigate } from 'react-router-dom'
import { useQuery } from '@tanstack/react-query'
import { listPlayers, type PlayerSummary } from '../utils/cloudSync'

export default function PlayerHistoryPage() {
  const navigate = useNavigate()

  const { data: players = [], isLoading, isError } = useQuery<PlayerSummary[]>({
    queryKey: ['players'],
    queryFn: listPlayers,
  })

  if (isLoading) return <p className="text-slate-400 text-sm">Loading players…</p>
  if (isError) return <p className="text-red-400 text-sm">Failed to load players.</p>

  return (
    <div className="flex flex-col gap-3">
      <h2 className="text-lg font-bold text-white">Player History</h2>
      {players.length === 0 && (
        <p className="text-slate-400 text-sm">No players found.</p>
      )}
      {players.map((p) => (
        <button
          key={p.name}
          onClick={() => navigate(`/player-history/${encodeURIComponent(p.name)}`)}
          className="bg-slate-900 border border-slate-800 rounded-xl p-4 flex items-center justify-between hover:border-slate-600 transition-colors text-left w-full"
        >
          <div className="flex items-center gap-2">
            <p className="text-sm font-semibold text-white">{p.name}</p>
            <p className="text-xs text-slate-500">{p.gender === 'M' ? 'M' : 'F'}</p>
          </div>
          <span className="text-slate-600 text-lg">›</span>
        </button>
      ))}
    </div>
  )
}
```

- [ ] **Step 2: Verify no TypeScript errors**

```bash
npm run build
```

Expected: build succeeds.

- [ ] **Step 3: Commit**

```bash
git add src/pages/PlayerHistoryPage.tsx
git commit -m "feat: migrate PlayerHistoryPage to useQuery"
```

---

## Task 4: Replace PlayerDetailPage with useQuery

**Files:**
- Modify: `src/pages/PlayerDetailPage.tsx`

- [ ] **Step 1: Rewrite `PlayerDetailPage.tsx`**

Replace the entire file with:

```tsx
import { useParams, useNavigate } from 'react-router-dom'
import { useQuery } from '@tanstack/react-query'
import { getPlayerStats, type PlayerStats } from '../utils/cloudSync'

export default function PlayerDetailPage() {
  const { name } = useParams<{ name: string }>()
  const navigate = useNavigate()

  const { data: stats, isLoading, isError } = useQuery<PlayerStats>({
    queryKey: ['player', name],
    queryFn: () => getPlayerStats(decodeURIComponent(name!)),
    enabled: !!name,
  })

  if (isLoading) return <p className="text-slate-400 text-sm">Loading stats…</p>
  if (isError) return <p className="text-red-400 text-sm">Failed to load stats.</p>
  if (!stats) return null

  const winRate = stats.gamesPlayed > 0
    ? Math.round((stats.wins / stats.gamesPlayed) * 100)
    : 0

  return (
    <div className="flex flex-col gap-4">
      <button
        onClick={() => navigate(-1)}
        className="text-xs text-slate-400 hover:text-slate-200 self-start transition-colors"
      >
        ← Back
      </button>

      <h2 className="text-xl font-bold text-white">{stats.name}</h2>

      <div className="grid grid-cols-2 gap-3">
        {([
          { label: 'Games', value: stats.gamesPlayed },
          { label: 'Win Rate', value: `${winRate}%` },
          { label: 'Wins', value: stats.wins },
          { label: 'Losses', value: stats.losses },
        ] as const).map((stat) => (
          <div key={stat.label} className="bg-slate-900 border border-slate-800 rounded-xl p-4">
            <p className="text-xs text-slate-400">{stat.label}</p>
            <p className="text-2xl font-bold text-white mt-1">{stat.value}</p>
          </div>
        ))}
      </div>

      {stats.sessions.length > 0 && (
        <div className="bg-slate-900 border border-slate-800 rounded-xl p-4 flex flex-col gap-2">
          <p className="text-xs font-semibold text-slate-400 uppercase tracking-wider">
            Sessions ({stats.sessions.length})
          </p>
          {stats.sessions.map((s) => (
            <div key={s.id} className="flex justify-between text-sm">
              <span className="text-slate-200">{s.title || 'Untitled'}</span>
              <span className="text-slate-500">{s.date.split('-').reverse().join('-')}</span>
            </div>
          ))}
        </div>
      )}

      {stats.topPartners.length > 0 && (
        <div className="bg-slate-900 border border-slate-800 rounded-xl p-4 flex flex-col gap-2">
          <p className="text-xs font-semibold text-slate-400 uppercase tracking-wider">Top Partners</p>
          {stats.topPartners.map((p) => (
            <div key={p.name} className="flex items-center justify-between">
              <span className="text-sm text-slate-200">{p.name}</span>
              <div className="flex items-center gap-1.5 font-mono text-[9px]">
                <span className="text-emerald-400 font-semibold">{p.wins}W</span>
                <span className="text-red-400 font-semibold">{p.losses}L</span>
                <span className="text-slate-500">{p.count}×</span>
              </div>
            </div>
          ))}
        </div>
      )}

      {stats.topOpponents.length > 0 && (
        <div className="bg-slate-900 border border-slate-800 rounded-xl p-4 flex flex-col gap-2">
          <p className="text-xs font-semibold text-slate-400 uppercase tracking-wider">Top Opponents</p>
          {stats.topOpponents.map((p) => (
            <div key={p.name} className="flex items-center justify-between">
              <span className="text-sm text-slate-200">{p.name}</span>
              <div className="flex items-center gap-1.5 font-mono text-[9px]">
                <span className="text-emerald-400 font-semibold">{p.wins}W</span>
                <span className="text-red-400 font-semibold">{p.losses}L</span>
                <span className="text-slate-500">{p.count}×</span>
              </div>
            </div>
          ))}
        </div>
      )}
    </div>
  )
}
```

- [ ] **Step 2: Verify no TypeScript errors**

```bash
npm run build
```

Expected: build succeeds.

- [ ] **Step 3: Commit**

```bash
git add src/pages/PlayerDetailPage.tsx
git commit -m "feat: migrate PlayerDetailPage to useQuery"
```

---

## Task 5: Add `saving` prop to SummaryModal

**Files:**
- Modify: `src/components/SummaryModal.tsx`

- [ ] **Step 1: Add `saving` to the props interface**

In `SummaryModal.tsx`, find the props destructuring block (around line 100) and add `saving` as an optional boolean:

```tsx
export default function SummaryModal({
  result,
  playerMap,
  slotsPerCourt,
  courtNames,
  playedGames: playedArr,
  gameScores,
  onTogglePlayedGame,
  onSetGameScore,
  onClose,
  title,
  date,
  sessionStart,
  slotMinutes,
  courtTimes,
  saving = false,
}: {
  result: GeneratorResult
  playerMap: Map<string, Player>
  slotsPerCourt: number[]
  courtNames: string[]
  playedGames: string[]
  gameScores: Record<string, GameScore>
  onTogglePlayedGame: (key: string) => void
  onSetGameScore: (key: string, a: number, b: number) => void
  onClose?: () => void
  title: string
  date: string
  sessionStart: string
  slotMinutes: number
  courtTimes: CourtTime[]
  saving?: boolean
})
```

- [ ] **Step 2: Disable the played checkbox while saving**

Find the played checkbox div (around line 278). Change:

```tsx
<div
  className={`w-4 h-4 shrink-0 rounded border flex items-center justify-center transition-colors cursor-pointer ${done ? 'bg-emerald-600 border-emerald-500' : 'border-slate-600 bg-slate-800'}`}
  onClick={() => onTogglePlayedGame(key)}
>
```

To:

```tsx
<div
  className={`w-4 h-4 shrink-0 rounded border flex items-center justify-center transition-colors ${saving ? 'cursor-not-allowed opacity-50' : 'cursor-pointer'} ${done ? 'bg-emerald-600 border-emerald-500' : 'border-slate-600 bg-slate-800'}`}
  onClick={() => { if (!saving) onTogglePlayedGame(key) }}
>
```

- [ ] **Step 3: Disable the Save button while saving**

Find the Save button in the expandable score panel (around line 352). Change:

```tsx
<button
  onClick={() => handleScoreSave(key)}
  className="px-6 py-1 rounded-lg bg-emerald-700 hover:bg-emerald-600 text-white text-xs font-bold transition-colors"
>
  ✓ Save
</button>
```

To:

```tsx
<button
  onClick={() => handleScoreSave(key)}
  disabled={saving}
  className="px-6 py-1 rounded-lg bg-emerald-700 hover:bg-emerald-600 text-white text-xs font-bold transition-colors disabled:opacity-50 disabled:cursor-not-allowed"
>
  {saving ? 'Saving…' : '✓ Save'}
</button>
```

- [ ] **Step 4: Verify no TypeScript errors**

```bash
npm run build
```

Expected: build succeeds.

- [ ] **Step 5: Commit**

```bash
git add src/components/SummaryModal.tsx
git commit -m "feat: add saving prop to SummaryModal for loading state"
```

---

## Task 6: Rewrite SharedSessionPage with useQuery + useMutation

**Files:**
- Modify: `src/pages/SharedSessionPage.tsx`

- [ ] **Step 1: Rewrite `SharedSessionPage.tsx`**

Replace the entire file with:

```tsx
import { useState } from 'react'
import { useParams, useNavigate } from 'react-router-dom'
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import { getSession, publishSession, type CloudSnapshot } from '../utils/cloudSync'
import type { GeneratorResult } from '../generator'
import SummaryModal from '../components/SummaryModal'

export default function SharedSessionPage() {
  const { sessionId } = useParams<{ sessionId: string }>()
  const navigate = useNavigate()
  const queryClient = useQueryClient()
  const [saveError, setSaveError] = useState<string | null>(null)

  const { data: snapshot, isLoading, isError } = useQuery<CloudSnapshot | null>({
    queryKey: ['session', sessionId],
    queryFn: () => getSession(sessionId!),
    enabled: !!sessionId,
  })

  const togglePlayed = useMutation({
    mutationFn: async (key: string) => {
      const current = queryClient.getQueryData<CloudSnapshot>(['session', sessionId])
      if (!current) throw new Error('no data')
      const nextPlayed = current.playedGames.includes(key)
        ? current.playedGames.filter((k) => k !== key)
        : [...current.playedGames, key]
      const updated: CloudSnapshot = { ...current, playedGames: nextPlayed }
      await publishSession(sessionId!, updated)
      return updated
    },
    onMutate: async (key) => {
      await queryClient.cancelQueries({ queryKey: ['session', sessionId] })
      const previous = queryClient.getQueryData<CloudSnapshot>(['session', sessionId])
      queryClient.setQueryData<CloudSnapshot | null>(['session', sessionId], (old) => {
        if (!old) return old
        const nextPlayed = old.playedGames.includes(key)
          ? old.playedGames.filter((k) => k !== key)
          : [...old.playedGames, key]
        return { ...old, playedGames: nextPlayed }
      })
      return { previous }
    },
    onSuccess: () => setSaveError(null),
    onError: (_err, _key, context) => {
      queryClient.setQueryData(['session', sessionId], context?.previous)
      setSaveError('Failed to save, please try again')
    },
    onSettled: () => {
      queryClient.invalidateQueries({ queryKey: ['session', sessionId] })
    },
  })

  const setScore = useMutation({
    mutationFn: async ({ key, a, b }: { key: string; a: number; b: number }) => {
      const current = queryClient.getQueryData<CloudSnapshot>(['session', sessionId])
      if (!current) throw new Error('no data')
      const nextScores = { ...current.gameScores, [key]: { a, b } }
      const nextPlayed = current.playedGames.includes(key)
        ? current.playedGames
        : [...current.playedGames, key]
      const updated: CloudSnapshot = { ...current, gameScores: nextScores, playedGames: nextPlayed }
      await publishSession(sessionId!, updated)
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
    onSuccess: () => setSaveError(null),
    onError: (_err, _vars, context) => {
      queryClient.setQueryData(['session', sessionId], context?.previous)
      setSaveError('Failed to save, please try again')
    },
    onSettled: () => {
      queryClient.invalidateQueries({ queryKey: ['session', sessionId] })
    },
  })

  if (isLoading) {
    return (
      <div className="fixed inset-0 bg-slate-950 flex items-center justify-center">
        <span className="text-slate-400 text-sm">Loading session…</span>
      </div>
    )
  }

  if (isError || !snapshot) {
    return (
      <div className="fixed inset-0 bg-slate-950 flex flex-col items-center justify-center gap-4">
        <span className="text-slate-300 text-sm">Session not found.</span>
        <button
          onClick={() => navigate('/')}
          className="text-xs text-indigo-400 hover:text-white underline underline-offset-2"
        >
          Go to home
        </button>
      </div>
    )
  }

  const playerMap = new Map(snapshot.players.map((p) => [p.id, p]))

  const result: GeneratorResult = {
    schedule: snapshot.schedule,
    playCount: {},
    sitCount: {},
    partnerWith: {},
    facedBy: {},
    unplacedFixMatches: [],
  }

  const isSaving = togglePlayed.isPending || setScore.isPending

  return (
    <>
      {saveError && (
        <div className="fixed top-4 left-1/2 -translate-x-1/2 z-[60] bg-red-900/90 border border-red-700 text-red-200 text-xs px-4 py-2 rounded-lg">
          {saveError}
        </div>
      )}
      <SummaryModal
        result={result}
        playerMap={playerMap}
        slotsPerCourt={snapshot.session.slotsPerCourt}
        courtNames={snapshot.session.courtNames ?? []}
        playedGames={snapshot.playedGames}
        gameScores={snapshot.gameScores}
        onTogglePlayedGame={(key) => togglePlayed.mutate(key)}
        onSetGameScore={(key, a, b) => setScore.mutate({ key, a, b })}
        title={snapshot.session.title ?? ''}
        date={snapshot.session.date ?? ''}
        sessionStart={snapshot.session.sessionStart}
        slotMinutes={snapshot.session.slotMinutes}
        courtTimes={snapshot.session.courtTimes}
        saving={isSaving}
      />
    </>
  )
}
```

- [ ] **Step 2: Verify no TypeScript errors**

```bash
npm run build
```

Expected: build succeeds with no errors.

- [ ] **Step 3: Commit**

```bash
git add src/pages/SharedSessionPage.tsx
git commit -m "feat: migrate SharedSessionPage to useQuery + useMutation with optimistic updates"
```

---

## Task 7: Wrap GeneratePage publishSession in useMutation

**Files:**
- Modify: `src/pages/GeneratePage.tsx`

- [ ] **Step 1: Add `useQueryClient` and `useMutation` import**

Find the existing import line at the top of `GeneratePage.tsx`:

```tsx
import { publishSession, type CloudSnapshot } from '../utils/cloudSync'
```

Add the React Query import below it:

```tsx
import { useMutation, useQueryClient } from '@tanstack/react-query'
```

- [ ] **Step 2: Add mutation inside the component**

Find the `playerMap` line inside the component (around line 415). Add these lines before it:

```tsx
const queryClient = useQueryClient()

const publish = useMutation({
  mutationFn: (snap: CloudSnapshot) => publishSession(cloudSessionId!, snap),
  onSuccess: (_data, snap) => {
    queryClient.setQueryData(['session', cloudSessionId], snap)
  },
})
```

- [ ] **Step 3: Replace publishSession calls in handleTogglePlayed**

Find `handleTogglePlayed` (around line 417). Replace the entire function:

```tsx
async function handleTogglePlayed(key: string) {
  togglePlayedGame(key)
  if (!cloudSessionId) return
  const nextPlayed = playedArr.includes(key)
    ? playedArr.filter((k) => k !== key)
    : [...playedArr, key]
  const snap: CloudSnapshot = { session, players, fixMatches, schedule, playedGames: nextPlayed, gameScores }
  publish.mutate(snap)
}
```

- [ ] **Step 4: Replace publishSession call in handleSetScore**

Find `handleSetScore` (around line 427). Replace the entire function:

```tsx
async function handleSetScore(key: string, a: number, b: number) {
  setGameScore(key, a, b)
  if (!cloudSessionId) return
  const nextScores = { ...gameScores, [key]: { a, b } }
  const snap: CloudSnapshot = { session, players, fixMatches, schedule, playedGames: playedArr, gameScores: nextScores }
  publish.mutate(snap)
}
```

- [ ] **Step 5: Verify no TypeScript errors**

```bash
npm run build
```

Expected: build succeeds.

- [ ] **Step 6: Commit**

```bash
git add src/pages/GeneratePage.tsx
git commit -m "feat: migrate GeneratePage publishSession to useMutation"
```
