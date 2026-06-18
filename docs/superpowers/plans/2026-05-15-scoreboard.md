# Scoreboard Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a full-screen live scoreboard page (Red vs Blue) with tap-to-score, minus, reset, and swap — persisted via localStorage.

**Architecture:** Single new page component (`ScoreboardPage`) with local `useState`. No Zustand store needed. Scores are read/written to `localStorage` on every change so they survive refresh. The page is added under `HomeLayout` at `/scoreboard` and linked from `HomePage`.

**Tech Stack:** React 19, TypeScript, Tailwind v4, react-router-dom v7, localStorage

---

## File Map

| File | Action |
|------|--------|
| `src/pages/ScoreboardPage.tsx` | **Create** — full-screen scoreboard component |
| `src/App.tsx` | **Modify** — import + add `/scoreboard` route under HomeLayout |
| `src/pages/HomePage.tsx` | **Modify** — add Scoreboard card to the 2×2 grid |

---

### Task 1: Create ScoreboardPage

**Files:**
- Create: `src/pages/ScoreboardPage.tsx`

- [ ] **Step 1: Create the file with this exact content**

```tsx
import { useState, useCallback, useEffect, useRef } from 'react'

const LS_RED = 'score-red'
const LS_BLUE = 'score-blue'

function readLS(key: string) {
  const v = localStorage.getItem(key)
  return v !== null ? parseInt(v, 10) : 0
}

export default function ScoreboardPage() {
  const [red, setRed] = useState(() => readLS(LS_RED))
  const [blue, setBlue] = useState(() => readLS(LS_BLUE))
  const [popRed, setPopRed] = useState(false)
  const [popBlue, setPopBlue] = useState(false)
  const redTimer = useRef<ReturnType<typeof setTimeout> | null>(null)
  const blueTimer = useRef<ReturnType<typeof setTimeout> | null>(null)

  useEffect(() => { localStorage.setItem(LS_RED, String(red)) }, [red])
  useEffect(() => { localStorage.setItem(LS_BLUE, String(blue)) }, [blue])

  function triggerPop(side: 'red' | 'blue') {
    if (side === 'red') {
      setPopRed(true)
      if (redTimer.current) clearTimeout(redTimer.current)
      redTimer.current = setTimeout(() => setPopRed(false), 180)
    } else {
      setPopBlue(true)
      if (blueTimer.current) clearTimeout(blueTimer.current)
      blueTimer.current = setTimeout(() => setPopBlue(false), 180)
    }
  }

  const addRed = useCallback(() => { setRed(r => r + 1); triggerPop('red') }, [])
  const addBlue = useCallback(() => { setBlue(b => b + 1); triggerPop('blue') }, [])

  const minusRed = useCallback((e: React.MouseEvent) => {
    e.stopPropagation()
    setRed(r => Math.max(0, r - 1))
    triggerPop('red')
  }, [])

  const minusBlue = useCallback((e: React.MouseEvent) => {
    e.stopPropagation()
    setBlue(b => Math.max(0, b - 1))
    triggerPop('blue')
  }, [])

  const reset = useCallback(() => { setRed(0); setBlue(0) }, [])

  const doSwap = useCallback(() => {
    const r = red
    const b = blue
    setRed(b)
    setBlue(r)
  }, [red, blue])

  return (
    <div className="flex w-screen h-screen overflow-hidden select-none">

      {/* Red side */}
      <div
        className="flex-1 flex flex-col items-center justify-center relative cursor-pointer active:brightness-125 transition-[filter] duration-75"
        style={{ background: '#7f1d1d' }}
        onClick={addRed}
      >
        <span className="text-[clamp(0.6rem,1.8vw,0.85rem)] tracking-[0.18em] uppercase font-semibold text-white/50 pointer-events-none">
          Red
        </span>
        <span
          className="text-white font-black leading-none pointer-events-none"
          style={{
            fontSize: 'clamp(6rem, 22vw, 13rem)',
            transform: popRed ? 'scale(1.1)' : 'scale(1)',
            transition: 'transform 0.08s ease-out',
          }}
        >
          {red}
        </span>
        <span className="text-white/20 text-[clamp(0.5rem,1vw,0.7rem)] tracking-widest mt-3 pointer-events-none">
          tap to score
        </span>
        <button
          onClick={minusRed}
          className="absolute bottom-14 w-11 h-11 rounded-full flex items-center justify-center text-xl font-bold text-white/60 cursor-pointer active:bg-black/40 transition-colors"
          style={{ background: 'rgba(0,0,0,0.22)', border: '1px solid rgba(255,255,255,0.15)' }}
        >
          −
        </button>
      </div>

      {/* Divider */}
      <div className="absolute left-1/2 top-[10%] h-[80%] w-px bg-white/8 pointer-events-none z-10" />

      {/* Blue side */}
      <div
        className="flex-1 flex flex-col items-center justify-center relative cursor-pointer active:brightness-125 transition-[filter] duration-75"
        style={{ background: '#1e3a8a' }}
        onClick={addBlue}
      >
        <span className="text-[clamp(0.6rem,1.8vw,0.85rem)] tracking-[0.18em] uppercase font-semibold text-white/50 pointer-events-none">
          Blue
        </span>
        <span
          className="text-white font-black leading-none pointer-events-none"
          style={{
            fontSize: 'clamp(6rem, 22vw, 13rem)',
            transform: popBlue ? 'scale(1.1)' : 'scale(1)',
            transition: 'transform 0.08s ease-out',
          }}
        >
          {blue}
        </span>
        <span className="text-white/20 text-[clamp(0.5rem,1vw,0.7rem)] tracking-widest mt-3 pointer-events-none">
          tap to score
        </span>
        <button
          onClick={minusBlue}
          className="absolute bottom-14 w-11 h-11 rounded-full flex items-center justify-center text-xl font-bold text-white/60 cursor-pointer active:bg-black/40 transition-colors"
          style={{ background: 'rgba(0,0,0,0.22)', border: '1px solid rgba(255,255,255,0.15)' }}
        >
          −
        </button>
      </div>

      {/* Bottom action bar */}
      <div
        className="absolute bottom-0 left-0 right-0 h-12 flex items-center justify-center gap-4 z-20"
        style={{ background: 'rgba(0,0,0,0.35)', borderTop: '1px solid rgba(255,255,255,0.06)' }}
      >
        <button
          onClick={reset}
          className="px-5 py-1.5 rounded-lg text-white/55 text-[0.72rem] tracking-wide cursor-pointer active:bg-white/10 transition-colors"
          style={{ background: 'rgba(255,255,255,0.06)', border: '1px solid rgba(255,255,255,0.1)' }}
        >
          ↺ Reset
        </button>
        <button
          onClick={doSwap}
          className="px-5 py-1.5 rounded-lg text-white/55 text-[0.72rem] tracking-wide cursor-pointer active:bg-white/10 transition-colors"
          style={{ background: 'rgba(255,255,255,0.06)', border: '1px solid rgba(255,255,255,0.1)' }}
        >
          ⇄ Swap
        </button>
      </div>

    </div>
  )
}
```

- [ ] **Step 2: Verify the file was created**

```bash
ls src/pages/ScoreboardPage.tsx
```

Expected: file listed with no error.

- [ ] **Step 3: Commit**

```bash
git add src/pages/ScoreboardPage.tsx
git commit -m "feat: add ScoreboardPage component"
```

---

### Task 2: Wire up the route in App.tsx

**Files:**
- Modify: `src/App.tsx`

- [ ] **Step 1: Add the import after the existing page imports**

In `src/App.tsx`, after the line:
```tsx
import InstagramPostPage from './pages/InstagramPostPage'
```
Add:
```tsx
import ScoreboardPage from './pages/ScoreboardPage'
```

- [ ] **Step 2: Add the route inside the HomeLayout Route group**

In `src/App.tsx`, inside `<Route element={<HomeLayout />}>`, after:
```tsx
<Route path="instagram-post" element={<InstagramPostPage />} />
```
Add:
```tsx
<Route path="scoreboard" element={<ScoreboardPage />} />
```

- [ ] **Step 3: Commit**

```bash
git add src/App.tsx
git commit -m "feat: add /scoreboard route"
```

---

### Task 3: Add Scoreboard card to HomePage

**Files:**
- Modify: `src/pages/HomePage.tsx`

- [ ] **Step 1: Add the Scoreboard entry to the grid array**

In `src/pages/HomePage.tsx`, update the `grid` array from:
```tsx
const grid = [
  { icon: '🏸', label: 'Create Session', description: 'Set up a new game', to: '/session/new' },
  { icon: '📋', label: 'Sessions', description: 'Browse past sessions', to: '/sessions' },
  { icon: '👤', label: 'Player History', description: 'Stats & records', to: '/player-history' },
  { icon: '📸', label: 'Instagram Post', description: 'Create a post from template', to: '/instagram-post' },
] as const
```
To:
```tsx
const grid = [
  { icon: '🏸', label: 'Create Session', description: 'Set up a new game', to: '/session/new' },
  { icon: '📋', label: 'Sessions', description: 'Browse past sessions', to: '/sessions' },
  { icon: '👤', label: 'Player History', description: 'Stats & records', to: '/player-history' },
  { icon: '🎯', label: 'Scoreboard', description: 'Live match scoring', to: '/scoreboard' },
  { icon: '📸', label: 'Instagram Post', description: 'Create a post from template', to: '/instagram-post' },
] as const
```

- [ ] **Step 2: Commit**

```bash
git add src/pages/HomePage.tsx
git commit -m "feat: add Scoreboard to home page grid"
```

---

### Task 4: Manual verification

- [ ] **Step 1: Start the dev server**

```bash
npm run dev
```

- [ ] **Step 2: Verify these behaviours**

1. Home page shows a "Scoreboard" card
2. Clicking the card navigates to `/scoreboard`
3. Page is full-screen red/blue split
4. Tapping each side increments the score
5. `−` button decrements (stops at 0, doesn't trigger +1)
6. Reset sets both scores to 0
7. Swap exchanges the two scores
8. Refresh the page — scores are restored from localStorage

- [ ] **Step 3: Run type-check**

```bash
npm run build
```

Expected: no TypeScript errors.
