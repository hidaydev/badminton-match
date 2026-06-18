# Scoreboard Overlay Redesign — Design Spec

**Date:** 2026-05-17

## Overview

Bring the scoreboard overlay fully in line with the existing standalone `ScoreboardPage` behaviour. Only three things differ: names are fixed (from match props, not editable), the close button is ✕ instead of ←, and Save Score triggers a pre-fetch before writing.

---

## ScoreboardPage — overlay mode changes

### Portrait rotation

The overlay wrapper currently uses `fixed inset-0 z-[60] flex overflow-hidden` with no rotation. It must use the **same CSS** as standalone mode, plus `z-[60]`:

```
portrait → position:fixed, top:0, left:100vw, width:100dvh, height:100dvw,
           transformOrigin:top left, transform:rotate(90deg), z-index:60
landscape → position:fixed, inset:0, z-index:60, display:flex, overflow:hidden
```

### Names — read-only pill badge

In overlay mode, `redName` and `blueName` are initialised from `overlay.pairAName` / `overlay.pairBName` and are **not editable**. The editable input/span is replaced with:

```tsx
<span
  className="text-[clamp(0.75rem,2.2vmax,1rem)] tracking-[0.12em] uppercase font-bold text-white truncate px-4 py-1 rounded-full pointer-events-none"
  style={{ background: 'rgba(0,0,0,0.25)' }}
>
  {name}
</span>
```

Names still participate in swap — `doSwap` swaps `redName ↔ blueName` as normal.

### Close button

In overlay mode the ← button is replaced with ✕. It calls `handleOverlayClose` (same pendingClose nav guard):

```tsx
<button onClick={handleOverlayClose} ...>✕</button>
```

### Footer

Overlay footer: `✕  ↺  ⇄  ⛶  [Save Score]`  — fullscreen button kept, Save Score added last.

Save Score button shows **"Saving…"** and is `disabled` while `isSaving` is true.

### localStorage keys

Overlay uses per-match keys: `score-match-{matchId}-a` and `score-match-{matchId}-b`.

---

## Save Score — fetch-before-write flow

When Save Score is tapped in the overlay, we must fetch fresh tournament data before writing, because the match may have been updated while the scoreboard was open.

### OverlayConfig.onSave becomes async

```ts
export interface OverlayConfig {
  matchId: string
  pairAName: string
  pairBName: string
  onSave: (scoreA: number, scoreB: number) => Promise<void>  // was void
  onClose: () => void
}
```

### ScoreboardPage overlay save handler

```tsx
const [isSaving, setIsSaving] = useState(false)

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

Save Score button:
```tsx
<button onClick={handleSave} disabled={isSaving} ...>
  {isSaving ? 'Saving…' : 'Save Score'}
</button>
```

### ScoreModal — async onSave

`ScoreModal` receives a new `refetch` prop and builds the async callback passed to the overlay:

```tsx
interface Props {
  match: TournamentMatch
  pairAName: string
  pairBName: string
  onConfirm: (scoreA: number, scoreB: number) => void
  onClose: () => void
  isFetching?: boolean
  refetch: () => Promise<unknown>   // new prop
}
```

The overlay's `onSave`:
```tsx
onSave={async (sA, sB) => {
  await refetch()
  onConfirm(sA, sB)
  setShowScoreboard(false)
}}
```

### GroupMatches — pass refetch

```tsx
interface Props {
  // ... existing props
  refetch: () => Promise<unknown>   // new prop
}
```

Passes it straight through to `ScoreModal`:
```tsx
<ScoreModal ... refetch={refetch} />
```

### TournamentPage — destructure refetch

```tsx
const { data: snapshot, isFetching, refetch } = useGetTournament()
```

Pass to `GroupMatches`:
```tsx
<GroupMatches ... refetch={refetch} />
```

---

## Files Changed

| File | Change |
|------|--------|
| `src/pages/ScoreboardPage.tsx` | Overlay: portrait rotation, ✕ button, read-only names, async handleSave, isSaving state |
| `src/components/tournament/ScoreModal.tsx` | Add `refetch` prop; async `onSave` with refetch→confirm |
| `src/components/tournament/GroupMatches.tsx` | Add `refetch` prop; pass to ScoreModal |
| `src/pages/TournamentPage.tsx` | Destructure `refetch` from `useGetTournament`; pass to GroupMatches |
