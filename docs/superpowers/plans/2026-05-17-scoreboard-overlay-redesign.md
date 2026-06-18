# Scoreboard Overlay Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bring the ScoreboardPage overlay mode fully in line with standalone behavior — same portrait rotation, swap swaps names, ✕ close button, async Save Score that refetches before writing.

**Architecture:** Three targeted changes: (1) fix overlay wrapper CSS + swap + close button in ScoreboardPage, (2) make onSave async with isSaving state in ScoreboardPage + OverlayConfig interface, (3) drill `refetch` from TournamentPage → GroupMatches → ScoreModal, where ScoreModal builds the async onSave callback.

**Tech Stack:** React 19, TypeScript, Tailwind v4, @tanstack/react-query v5

---

## File Map

| File | Change |
|------|--------|
| `src/pages/ScoreboardPage.tsx` | Fix overlay wrapper (portrait rotation + z-60), ✕ button, init names from overlay props, use doSwap in overlay, async handleSave + isSaving, update OverlayConfig.onSave type |
| `src/components/tournament/ScoreModal.tsx` | Add `refetch` prop; make onSave async |
| `src/components/tournament/GroupMatches.tsx` | Add `refetch` prop; pass to ScoreModal |
| `src/pages/TournamentPage.tsx` | Destructure `refetch` from useGetTournament; pass to GroupMatches |

---

## Task 1: Fix overlay wrapper, names, swap, and close button in ScoreboardPage

**Files:**
- Modify: `src/pages/ScoreboardPage.tsx`

This task fixes everything in ScoreboardPage except the async save logic (that's Task 2).

- [ ] **Step 1: Initialize redName/blueName from overlay props**

Change the two `useState` initialisers for `redName` and `blueName`. The overlay prop is available in the closure at initialisation time.

Replace lines 49–50:
```tsx
const [redName, setRedName] = useState(() => { const v = localStorage.getItem('name-red'); return (v === 'Red' || v === null) ? '' : v })
const [blueName, setBlueName] = useState(() => { const v = localStorage.getItem('name-blue'); return (v === 'Blue' || v === null) ? '' : v })
```
With:
```tsx
const [redName, setRedName] = useState(() => {
  if (overlay) return overlay.pairAName
  const v = localStorage.getItem('name-red')
  return (v === 'Red' || v === null) ? '' : v
})
const [blueName, setBlueName] = useState(() => {
  if (overlay) return overlay.pairBName
  const v = localStorage.getItem('name-blue')
  return (v === 'Blue' || v === null) ? '' : v
})
```

- [ ] **Step 2: Update nameA/nameB to use redName/blueName in overlay mode**

Replace line 159–160:
```tsx
const nameA = overlay ? overlay.pairAName : (redName || (leftColor === 'red' ? 'RED' : 'BLUE'))
const nameB = overlay ? overlay.pairBName : (blueName || (leftColor === 'red' ? 'BLUE' : 'RED'))
```
With:
```tsx
const nameA = overlay ? redName : (redName || (leftColor === 'red' ? 'RED' : 'BLUE'))
const nameB = overlay ? blueName : (blueName || (leftColor === 'red' ? 'BLUE' : 'RED'))
```

Names are now driven by `redName`/`blueName` state (initialised from overlay props), so `doSwap` — which already swaps `redName ↔ blueName` — will swap the pill labels correctly.

- [ ] **Step 3: Remove doSwapOverlay; use doSwap in the overlay footer ⇄ button**

Delete the entire `doSwapOverlay` callback (lines 137–141):
```tsx
const doSwapOverlay = useCallback(() => {
  setRed(blue)
  setBlue(red)
  setLeftColor(c => c === 'red' ? 'blue' : 'red')
}, [red, blue])
```

In the overlay footer's ⇄ button (currently `onClick={doSwapOverlay}`), change to `onClick={doSwap}`. `doSwap` already swaps scores + names + leftColor, which is exactly what we want.

The ⇄ button looks like this after the change:
```tsx
<button
  onClick={doSwap}
  className="px-3 py-1 rounded-lg text-white/55 text-lg cursor-pointer active:bg-white/10 transition-colors pointer-events-auto"
  style={{ background: 'rgba(255,255,255,0.06)', border: '1px solid rgba(255,255,255,0.1)' }}
>
  ⇄
</button>
```

- [ ] **Step 4: Change ← to ✕ in the overlay footer close button**

In the overlay footer (the non-pendingClose branch), the first button currently shows `←` and calls `handleOverlayClose`. Change the button text only:
```tsx
<button
  onClick={handleOverlayClose}
  className="px-3 py-1 rounded-lg text-white/55 text-lg cursor-pointer active:bg-white/10 transition-colors pointer-events-auto"
  style={{ background: 'rgba(255,255,255,0.06)', border: '1px solid rgba(255,255,255,0.1)' }}
>
  ✕
</button>
```

- [ ] **Step 5: Fix overlay wrapper to use portrait rotation CSS + z-index 60**

Replace the overlay return block (lines 388–403) — currently `fixed inset-0 z-[60] flex overflow-hidden` — with the same portrait rotation logic as standalone mode, plus `zIndex: 60`:

```tsx
if (overlay) {
  return (
    <div
      className="flex overflow-hidden select-none"
      style={isPortrait ? {
        position: 'fixed',
        top: 0,
        left: '100vw',
        width: '100dvh',
        height: '100dvw',
        transformOrigin: 'top left',
        transform: 'rotate(90deg)',
        zIndex: 60,
      } : {
        position: 'fixed',
        inset: 0,
        zIndex: 60,
        display: 'flex',
        overflow: 'hidden',
      }}
    >
      {redSide}
      {divider}
      {blueSide}
      {fsError && (
        <div className="fixed bottom-14 left-1/2 -translate-x-1/2 z-30 px-4 py-2 rounded-lg text-xs text-white/80 max-w-[80vw] text-center"
          style={{ background: 'rgba(0,0,0,0.75)', border: '1px solid rgba(255,255,255,0.15)' }}>
          {fsError}
        </div>
      )}
      {footer}
    </div>
  )
}
```

- [ ] **Step 6: Verify in dev server**

Run: `npm run dev`

Open the app → Tournament → Groups tab → tap a match row → tap "🎯 Open Scoreboard".

Check:
- On a portrait phone/emulator: overlay rotates 90° (landscape scoreboard, same as standalone `/scoreboard` page)
- On a landscape device: overlay fills full screen without rotation
- Pill badges show pair names from the match
- Tapping ⇄ swaps both the score numbers AND the pair name pills
- Close button shows ✕ (not ←)
- Tapping ✕ with unchanged scores closes immediately; with changed scores shows "Discard / Keep scoring" panel

- [ ] **Step 7: Commit**

```bash
git add src/pages/ScoreboardPage.tsx
git commit -m "fix: overlay portrait rotation, ✕ close, swap swaps names"
```

---

## Task 2: Make onSave async with isSaving state

**Files:**
- Modify: `src/pages/ScoreboardPage.tsx`

- [ ] **Step 1: Update OverlayConfig.onSave type to Promise<void>**

Change line 37:
```ts
onSave: (scoreA: number, scoreB: number) => void
```
To:
```ts
onSave: (scoreA: number, scoreB: number) => Promise<void>
```

- [ ] **Step 2: Add isSaving state**

After line 59 (`const [pendingClose, setPendingClose] = useState(false)`), add:
```tsx
const [isSaving, setIsSaving] = useState(false)
```

- [ ] **Step 3: Make handleSave async with isSaving guard**

Replace the `handleSave` callback (lines 152–156):
```tsx
const handleSave = useCallback(() => {
  if (!overlay) return
  overlay.onSave(red, blue)
  overlay.onClose()
}, [overlay, red, blue])
```
With:
```tsx
const handleSave = useCallback(async () => {
  if (!overlay || isSaving) return
  setIsSaving(true)
  try {
    await overlay.onSave(red, blue)
    overlay.onClose()
  } finally {
    setIsSaving(false)
  }
}, [overlay, red, blue, isSaving])
```

- [ ] **Step 4: Update Save Score button to show Saving… and disable while saving**

In the overlay footer, find the Save Score button and replace it:
```tsx
<button
  onClick={handleSave}
  disabled={isSaving}
  className="px-4 py-1 rounded-lg text-slate-900 font-bold text-sm cursor-pointer active:opacity-80 transition-opacity pointer-events-auto disabled:opacity-50 disabled:cursor-not-allowed"
  style={{ background: '#fbbf24' }}
>
  {isSaving ? 'Saving…' : 'Save Score'}
</button>
```

- [ ] **Step 5: Verify TypeScript compiles**

Run: `npm run build`

Expected: no TypeScript errors. The `onSave` prop in `ScoreModal.tsx` currently passes a sync callback `(sA, sB) => { ... }` — a sync function is assignable to `() => Promise<void>` in TypeScript (it returns `undefined`, which is a valid Promise-less return). This is fine until Task 3 makes it properly async.

- [ ] **Step 6: Commit**

```bash
git add src/pages/ScoreboardPage.tsx
git commit -m "feat: async handleSave with isSaving state in scoreboard overlay"
```

---

## Task 3: Wire refetch prop chain and async onSave in ScoreModal

**Files:**
- Modify: `src/pages/TournamentPage.tsx`
- Modify: `src/components/tournament/GroupMatches.tsx`
- Modify: `src/components/tournament/ScoreModal.tsx`

- [ ] **Step 1: Destructure refetch in TournamentPage**

Change line 80:
```tsx
const { data: snapshot, isFetching } = useGetTournament()
```
To:
```tsx
const { data: snapshot, isFetching, refetch } = useGetTournament()
```

- [ ] **Step 2: Pass refetch to GroupMatches in TournamentPage**

Find the `<GroupMatches ... />` JSX (around line 165–182) and add the `refetch` prop:
```tsx
<GroupMatches
  pairs={pairs}
  groups={committedGroups}
  matches={matches}
  onSetMatchScore={(id, a, b) => setTournamentScore({ matchId: id, scoreA: a, scoreB: b }, {
    onSuccess: () => setSaveError(null),
    onError: () => setSaveError('Failed to save score, please try again'),
  })}
  onResetGroups={() => resetTournament({ name, date, pairs }, {
    onSuccess: () => {
      setSaveError(null)
      setLocalGroups(EMPTY_GROUPS)
    },
    onError: () => setSaveError('Failed to reset, please try again'),
  })}
  onOpenModal={handleOpenModal}
  isFetching={isFetching}
  refetch={refetch}
/>
```

- [ ] **Step 3: Add refetch prop to GroupMatches**

In `src/components/tournament/GroupMatches.tsx`, add `refetch` to the Props interface (after `isFetching`):
```tsx
interface Props {
  pairs: TournamentPair[]
  groups: Record<GroupId, string[]>
  matches: TournamentMatch[]
  onSetMatchScore: (matchId: string, scoreA: number, scoreB: number) => void
  onResetGroups: () => void
  onOpenModal: () => void
  isFetching: boolean
  refetch: () => Promise<unknown>
}
```

Destructure it in the function signature:
```tsx
export default function GroupMatches({ pairs, groups, matches, onSetMatchScore, onResetGroups, onOpenModal, isFetching, refetch }: Props) {
```

- [ ] **Step 4: Pass refetch to ScoreModal in GroupMatches**

Find the `<ScoreModal ... />` JSX (around line 97–105) and add `refetch={refetch}`:
```tsx
{activeMatch && (
  <ScoreModal
    match={activeMatch}
    pairAName={getPairName(activeMatch.pairAId)}
    pairBName={getPairName(activeMatch.pairBId)}
    onConfirm={(a, b) => { onSetMatchScore(activeMatch.id, a, b); setActiveMatchId(null) }}
    onClose={() => setActiveMatchId(null)}
    isFetching={isFetching}
    refetch={refetch}
  />
)}
```

- [ ] **Step 5: Add refetch prop to ScoreModal and make onSave async**

In `src/components/tournament/ScoreModal.tsx`, update the Props interface to add `refetch`:
```tsx
interface Props {
  match: TournamentMatch
  pairAName: string
  pairBName: string
  onConfirm: (scoreA: number, scoreB: number) => void
  onClose: () => void
  isFetching?: boolean
  refetch: () => Promise<unknown>
}
```

Update the function signature to destructure `refetch`:
```tsx
export default function ScoreModal({ match, pairAName, pairBName, onConfirm, onClose, isFetching = false, refetch }: Props) {
```

Update the `onSave` callback passed to `ScoreboardOverlay`:
```tsx
if (showScoreboard) {
  return (
    <ScoreboardOverlay
      matchId={match.id}
      pairAName={pairAName}
      pairBName={pairBName}
      onSave={async (sA, sB) => {
        await refetch()
        onConfirm(sA, sB)
        setShowScoreboard(false)
      }}
      onClose={() => setShowScoreboard(false)}
    />
  )
}
```

- [ ] **Step 6: Verify TypeScript compiles**

Run: `npm run build`

Expected: clean build with no errors. The async `onSave` callback now matches the `Promise<void>` type in `OverlayConfig`.

- [ ] **Step 7: Verify end-to-end in dev server**

Run: `npm run dev`

Test the full flow:
1. Open app → Tournament → Groups tab → tap a match row
2. Tap "🎯 Open Scoreboard" — overlay opens with correct pair names as pill badges
3. Score a few points
4. Tap "Save Score" — button shows "Saving…" briefly, then the modal closes and the score appears in the match row
5. Reopen the same match — scoreboard resumes from the saved score (localStorage per-match keys)
6. Score more points, tap ✕ — "Discard / Keep scoring" panel appears
7. Tap "Discard" — overlay closes without saving

- [ ] **Step 8: Commit**

```bash
git add src/pages/TournamentPage.tsx src/components/tournament/GroupMatches.tsx src/components/tournament/ScoreModal.tsx
git commit -m "feat: refetch-before-write on scoreboard overlay save"
```
