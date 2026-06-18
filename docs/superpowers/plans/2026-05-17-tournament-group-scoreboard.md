# Tournament Group Scoreboard Overlay Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a live scoreboard overlay to the tournament group matches flow, launched from ScoreModal, with per-match localStorage persistence and a save-back mechanism.

**Architecture:** A new `ScoreboardOverlay` component renders as a `fixed inset-0 z-60` overlay (no navigation), pre-filled with pair names from the match. `ScoreModal` gains a ghost "Open Scoreboard" button and renders the overlay via local state. Match row buttons in `GroupMatches` get active tap feedback.

**Tech Stack:** React 19, TypeScript, Tailwind v4, localStorage

---

## File Map

| File | Action |
|------|--------|
| `src/components/tournament/ScoreboardOverlay.tsx` | Create — full-screen scoreboard overlay component |
| `src/components/tournament/ScoreModal.tsx` | Modify — add `showScoreboard` state, ghost button, render overlay |
| `src/components/tournament/GroupMatches.tsx` | Modify — add `active:` press feedback to match row buttons |

---

### Task 1: Create ScoreboardOverlay component

**Files:**
- Create: `src/components/tournament/ScoreboardOverlay.tsx`

- [ ] **Step 1: Create the component file**

```tsx
import { useState, useCallback, useRef, useEffect } from 'react'

interface Props {
  matchId: string
  pairAName: string
  pairBName: string
  onSave: (scoreA: number, scoreB: number) => void
  onClose: () => void
}

function readLS(key: string): number {
  const v = localStorage.getItem(key)
  if (v === null) return 0
  const parsed = parseInt(v, 10)
  return Number.isFinite(parsed) ? parsed : 0
}

export default function ScoreboardOverlay({ matchId, pairAName, pairBName, onSave, onClose }: Props) {
  const keyA = `score-match-${matchId}-a`
  const keyB = `score-match-${matchId}-b`

  const [scoreA, setScoreA] = useState(() => readLS(keyA))
  const [scoreB, setScoreB] = useState(() => readLS(keyB))
  const [popA, setPopA] = useState(false)
  const [popB, setPopB] = useState(false)

  const initialA = useRef(readLS(keyA))
  const initialB = useRef(readLS(keyB))
  const timerA = useRef<ReturnType<typeof setTimeout> | null>(null)
  const timerB = useRef<ReturnType<typeof setTimeout> | null>(null)

  useEffect(() => { localStorage.setItem(keyA, String(scoreA)) }, [scoreA, keyA])
  useEffect(() => { localStorage.setItem(keyB, String(scoreB)) }, [scoreB, keyB])

  useEffect(() => {
    return () => {
      if (timerA.current) clearTimeout(timerA.current)
      if (timerB.current) clearTimeout(timerB.current)
    }
  }, [])

  function triggerPop(side: 'a' | 'b') {
    if (side === 'a') {
      setPopA(true)
      if (timerA.current) clearTimeout(timerA.current)
      timerA.current = setTimeout(() => setPopA(false), 180)
    } else {
      setPopB(true)
      if (timerB.current) clearTimeout(timerB.current)
      timerB.current = setTimeout(() => setPopB(false), 180)
    }
  }

  const addA = useCallback(() => { setScoreA(s => s + 1); triggerPop('a') }, [])
  const addB = useCallback(() => { setScoreB(s => s + 1); triggerPop('b') }, [])

  const minusA = useCallback((e: React.MouseEvent) => {
    e.stopPropagation()
    setScoreA(s => Math.max(0, s - 1))
    triggerPop('a')
  }, [])

  const minusB = useCallback((e: React.MouseEvent) => {
    e.stopPropagation()
    setScoreB(s => Math.max(0, s - 1))
    triggerPop('b')
  }, [])

  const reset = useCallback(() => { setScoreA(0); setScoreB(0) }, [])

  const swap = useCallback(() => {
    setScoreA(scoreB)
    setScoreB(scoreA)
  }, [scoreA, scoreB])

  const handleClose = useCallback(() => {
    if (scoreA !== initialA.current || scoreB !== initialB.current) {
      if (!window.confirm('Discard unsaved score?')) return
    }
    onClose()
  }, [scoreA, scoreB, onClose])

  const handleSave = useCallback(() => {
    onSave(scoreA, scoreB)
    onClose()
  }, [scoreA, scoreB, onSave, onClose])

  return (
    <div className="fixed inset-0 z-[60] flex flex-col select-none">
      {/* Score area */}
      <div className="flex flex-1 overflow-hidden">
        {/* Side A — red */}
        <div
          className="flex-1 flex flex-col items-center justify-center relative cursor-pointer active:brightness-150 transition-[filter] duration-75"
          style={{ background: '#b91c1c' }}
          onClick={addA}
        >
          <div className="absolute top-0 left-0 right-0 flex justify-center pt-4 pointer-events-none">
            <span className="text-[clamp(0.65rem,2vmax,0.9rem)] tracking-[0.18em] uppercase font-bold text-white/40 truncate px-4 text-center">
              {pairAName}
            </span>
          </div>
          <span
            className="text-white font-black leading-none pointer-events-none"
            style={{
              fontSize: 'clamp(6rem, 22vmax, 13rem)',
              transform: popA ? 'scale(1.1)' : 'scale(1)',
              transition: 'transform 0.08s ease-out',
            }}
          >
            {scoreA}
          </span>
          <span className="text-white/20 text-[clamp(0.55rem,1.2vmax,0.75rem)] tracking-widest mt-3 pointer-events-none">
            tap to score
          </span>
          <button
            onClick={minusA}
            className="absolute right-4 top-1/2 -translate-y-1/2 w-11 h-11 rounded-full flex items-center justify-center text-xl font-bold text-white/60 cursor-pointer active:bg-black/40 transition-colors"
            style={{ background: 'rgba(0,0,0,0.22)', border: '1px solid rgba(255,255,255,0.15)' }}
          >
            −
          </button>
        </div>

        {/* Divider */}
        <div className="absolute left-1/2 top-[10%] h-[80%] w-px bg-white/8 pointer-events-none z-10" />

        {/* Side B — blue */}
        <div
          className="flex-1 flex flex-col items-center justify-center relative cursor-pointer active:brightness-150 transition-[filter] duration-75"
          style={{ background: '#1d4ed8' }}
          onClick={addB}
        >
          <div className="absolute top-0 left-0 right-0 flex justify-center pt-4 pointer-events-none">
            <span className="text-[clamp(0.65rem,2vmax,0.9rem)] tracking-[0.18em] uppercase font-bold text-white/40 truncate px-4 text-center">
              {pairBName}
            </span>
          </div>
          <span
            className="text-white font-black leading-none pointer-events-none"
            style={{
              fontSize: 'clamp(6rem, 22vmax, 13rem)',
              transform: popB ? 'scale(1.1)' : 'scale(1)',
              transition: 'transform 0.08s ease-out',
            }}
          >
            {scoreB}
          </span>
          <span className="text-white/20 text-[clamp(0.55rem,1.2vmax,0.75rem)] tracking-widest mt-3 pointer-events-none">
            tap to score
          </span>
          <button
            onClick={minusB}
            className="absolute left-4 top-1/2 -translate-y-1/2 w-11 h-11 rounded-full flex items-center justify-center text-xl font-bold text-white/60 cursor-pointer active:bg-black/40 transition-colors"
            style={{ background: 'rgba(0,0,0,0.22)', border: '1px solid rgba(255,255,255,0.15)' }}
          >
            −
          </button>
        </div>
      </div>

      {/* Footer action bar */}
      <div
        className="flex items-center justify-center gap-3 z-20"
        style={{
          paddingTop: '0.5rem',
          paddingBottom: 'max(0.75rem, env(safe-area-inset-bottom))',
          background: 'rgba(0,0,0,0.35)',
          borderTop: '1px solid rgba(255,255,255,0.08)',
        }}
      >
        <button
          onClick={handleClose}
          className="px-3 py-1 rounded-lg text-white/55 text-lg cursor-pointer active:bg-white/10 transition-colors"
          style={{ background: 'rgba(255,255,255,0.06)', border: '1px solid rgba(255,255,255,0.1)' }}
        >
          ←
        </button>
        <button
          onClick={reset}
          className="px-3 py-1 rounded-lg text-white/55 text-lg cursor-pointer active:bg-white/10 transition-colors"
          style={{ background: 'rgba(255,255,255,0.06)', border: '1px solid rgba(255,255,255,0.1)' }}
        >
          ↺
        </button>
        <button
          onClick={swap}
          className="px-3 py-1 rounded-lg text-white/55 text-lg cursor-pointer active:bg-white/10 transition-colors"
          style={{ background: 'rgba(255,255,255,0.06)', border: '1px solid rgba(255,255,255,0.1)' }}
        >
          ⇄
        </button>
        <button
          onClick={handleSave}
          className="px-4 py-1 rounded-lg text-slate-900 font-bold text-sm cursor-pointer active:opacity-80 transition-opacity"
          style={{ background: '#fbbf24' }}
        >
          Save Score
        </button>
      </div>
    </div>
  )
}
```

- [ ] **Step 2: Verify TypeScript compiles**

```bash
npm run build 2>&1 | head -40
```

Expected: no errors relating to `ScoreboardOverlay.tsx`

- [ ] **Step 3: Commit**

```bash
git add src/components/tournament/ScoreboardOverlay.tsx
git commit -m "feat: add ScoreboardOverlay component for live match scoring"
```

---

### Task 2: Wire ScoreboardOverlay into ScoreModal

**Files:**
- Modify: `src/components/tournament/ScoreModal.tsx`

- [ ] **Step 1: Add `showScoreboard` state and overlay render**

Replace the entire file content with:

```tsx
import { useState, useEffect } from 'react'
import type { TournamentMatch } from '../../utils/tournament'
import ScoreboardOverlay from './ScoreboardOverlay'

interface Props {
  match: TournamentMatch
  pairAName: string
  pairBName: string
  onConfirm: (scoreA: number, scoreB: number) => void
  onClose: () => void
  isFetching?: boolean
}

export default function ScoreModal({ match, pairAName, pairBName, onConfirm, onClose, isFetching = false }: Props) {
  const [scoreA, setScoreA] = useState(match.scoreA?.toString() ?? '')
  const [scoreB, setScoreB] = useState(match.scoreB?.toString() ?? '')
  const [showScoreboard, setShowScoreboard] = useState(false)

  // Sync inputs with fresh match data once the refetch completes
  useEffect(() => {
    if (!isFetching) {
      setScoreA(match.scoreA?.toString() ?? '')
      setScoreB(match.scoreB?.toString() ?? '')
    }
  }, [isFetching, match.scoreA, match.scoreB])

  const a = parseInt(scoreA, 10)
  const b = parseInt(scoreB, 10)
  const valid = !isNaN(a) && !isNaN(b) && a >= 0 && b >= 0 && a !== b

  if (showScoreboard) {
    return (
      <ScoreboardOverlay
        matchId={match.id}
        pairAName={pairAName}
        pairBName={pairBName}
        onSave={(sA, sB) => {
          onConfirm(sA, sB)
          setShowScoreboard(false)
        }}
        onClose={() => setShowScoreboard(false)}
      />
    )
  }

  if (isFetching) {
    return (
      <div className="fixed inset-0 bg-black/70 z-50 flex items-end sm:items-center justify-center p-4" onClick={onClose}>
        <div className="bg-slate-800 rounded-2xl w-full max-w-sm p-5" onClick={(e) => e.stopPropagation()}>
          <div className="animate-pulse">
            <div className="h-5 bg-slate-700 rounded w-1/3 mx-auto mb-1" />
            <div className="h-4 bg-slate-700 rounded w-1/2 mx-auto mb-4" />
            <div className="flex items-center gap-3 mb-5">
              <div className="flex-1 flex flex-col items-center gap-1">
                <div className="h-4 bg-slate-700 rounded w-3/4" />
                <div className="h-[47px] bg-slate-700 rounded-xl w-full" />
              </div>
              <div className="w-6 shrink-0" />
              <div className="flex-1 flex flex-col items-center gap-1">
                <div className="h-4 bg-slate-700 rounded w-3/4" />
                <div className="h-[47px] bg-slate-700 rounded-xl w-full" />
              </div>
            </div>
            <div className="flex gap-3">
              <div className="flex-1 h-11 bg-slate-700 rounded-xl" />
              <div className="flex-1 h-11 bg-yellow-400/20 rounded-xl" />
            </div>
          </div>
        </div>
      </div>
    )
  }

  return (
    <div className="fixed inset-0 bg-black/70 z-50 flex items-end sm:items-center justify-center p-4" onClick={onClose}>
      <div className="bg-slate-800 rounded-2xl w-full max-w-sm p-5" onClick={(e) => e.stopPropagation()}>
        <h3 className="text-sm font-bold text-slate-300 text-center mb-1">Enter Score</h3>
        <p className="text-xs text-slate-500 text-center mb-4">
          {pairAName} vs {pairBName}
        </p>

        <div className="flex items-center gap-3 mb-5">
          <div className="flex-1 flex flex-col items-center gap-1">
            <span className="text-xs text-slate-400 font-medium truncate w-full text-center">{pairAName}</span>
            <input
              type="number"
              min={0}
              value={scoreA}
              onChange={(e) => setScoreA(e.target.value)}
              className="w-full bg-slate-900 border border-slate-700 rounded-xl px-3 py-3 text-2xl font-bold text-yellow-400 text-center focus:outline-none focus:border-yellow-500"
              placeholder="0"
            />
          </div>
          <span className="text-slate-600 font-bold text-lg pt-5">vs</span>
          <div className="flex-1 flex flex-col items-center gap-1">
            <span className="text-xs text-slate-400 font-medium truncate w-full text-center">{pairBName}</span>
            <input
              type="number"
              min={0}
              value={scoreB}
              onChange={(e) => setScoreB(e.target.value)}
              className="w-full bg-slate-900 border border-slate-700 rounded-xl px-3 py-3 text-2xl font-bold text-yellow-400 text-center focus:outline-none focus:border-yellow-500"
              placeholder="0"
            />
          </div>
        </div>

        {!isNaN(a) && !isNaN(b) && a === b && (
          <p className="text-xs text-red-400 text-center mb-3">Scores cannot be equal (no draws)</p>
        )}

        <div className="flex gap-3 mb-3">
          <button
            onClick={onClose}
            className="flex-1 py-3 rounded-xl bg-slate-700 text-slate-300 text-sm font-semibold"
          >
            Cancel
          </button>
          <button
            onClick={() => valid && onConfirm(a, b)}
            disabled={!valid}
            className="flex-1 py-3 rounded-xl bg-yellow-400 text-slate-900 text-sm font-bold disabled:opacity-40 disabled:cursor-not-allowed"
          >
            Confirm
          </button>
        </div>

        <button
          onClick={() => setShowScoreboard(true)}
          className="w-full py-2.5 rounded-xl text-slate-400 text-sm font-medium flex items-center justify-center gap-2 active:bg-slate-700/60 transition-colors"
          style={{ border: '1px solid rgba(148,163,184,0.15)' }}
        >
          🎯 Open Scoreboard
        </button>
      </div>
    </div>
  )
}
```

- [ ] **Step 2: Verify TypeScript compiles**

```bash
npm run build 2>&1 | head -40
```

Expected: no errors

- [ ] **Step 3: Commit**

```bash
git add src/components/tournament/ScoreModal.tsx
git commit -m "feat: add Open Scoreboard button to ScoreModal"
```

---

### Task 3: Add tap feedback to GroupMatches match rows

**Files:**
- Modify: `src/components/tournament/GroupMatches.tsx:53-65`

- [ ] **Step 1: Add active press classes to match row button**

Find the match row `<button>` (line 53) — currently:
```tsx
className="w-full flex items-center px-4 py-3 hover:bg-slate-700/50 text-left gap-2"
```

Change to:
```tsx
className="w-full flex items-center px-4 py-3 hover:bg-slate-700/50 active:bg-slate-600/60 active:scale-[0.98] transition-transform duration-75 text-left gap-2"
```

- [ ] **Step 2: Verify TypeScript compiles**

```bash
npm run build 2>&1 | head -40
```

Expected: no errors

- [ ] **Step 3: Commit**

```bash
git add src/components/tournament/GroupMatches.tsx
git commit -m "feat: add active tap feedback to group match rows"
```

---

### Task 4: Manual smoke test

- [ ] **Step 1: Start dev server**

```bash
npm run dev
```

Open the app in browser at `http://localhost:5173`

- [ ] **Step 2: Test tap feedback**

Navigate to Tournament → Groups tab (after locking groups, switch to Matches tab). Tap a match row — it should briefly scale down and darken on press.

- [ ] **Step 3: Test scoreboard overlay opens**

Tap a match row → ScoreModal opens. Scroll to bottom — "🎯 Open Scoreboard" ghost button should be visible below "Confirm" / "Cancel".

- [ ] **Step 4: Test scoring**

Tap "🎯 Open Scoreboard" → overlay opens full-screen with pair names shown faintly at top of each side. Tap the red side several times — score increments with pop animation. Tap `−` — score decrements. Tap `↺` — both reset to 0. Tap `⇄` — scores swap sides.

- [ ] **Step 5: Test navigation guard**

Score a few points. Tap `←` — confirm dialog "Discard unsaved score?" appears. Tap Cancel — overlay stays open. Tap `←` again, confirm — overlay closes, modal is back.

- [ ] **Step 6: Test Save Score**

Score a few points (e.g. 15–12). Tap "Save Score" — overlay closes, modal closes, match row now shows `15–12` in the score badge.

- [ ] **Step 7: Test localStorage isolation**

Open two different match rows one after another. Score different values in each. Refresh the page, re-open each match's scoreboard — each should show its own saved scores independently.

- [ ] **Step 8: Test no-change close**

Open scoreboard overlay without changing any score. Tap `←` — should close immediately without the confirm dialog.
