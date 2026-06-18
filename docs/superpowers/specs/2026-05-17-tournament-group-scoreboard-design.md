# Tournament Group Scoreboard Overlay — Design Spec

**Date:** 2026-05-17

## Overview

Add a live scoreboard overlay to the tournament group matches flow. From the existing score modal, a ghost "Open Scoreboard" button opens a full-screen overlay scoreboard pre-filled with the match's pair names. The user scores the game live, then taps "Save Score" to write the result back to the tournament and return to the modal.

## Entry Point

In `ScoreModal`, below the existing "Confirm Score" button, add a secondary ghost button:

```
[ Confirm Score ]          ← primary yellow CTA (existing)
[ 🎯 Open Scoreboard ]     ← new ghost button, below
```

Tapping it opens the `ScoreboardOverlay` component as a full-screen overlay (not a navigation).

## ScoreboardOverlay Component

New file: `src/components/tournament/ScoreboardOverlay.tsx`

### Props

```ts
interface Props {
  matchId: string
  pairAName: string
  pairBName: string
  onSave: (scoreA: number, scoreB: number) => void
  onClose: () => void
}
```

### Layout

Full-screen overlay (`position: fixed, inset: 0, z-index: 60`). Same two-panel landscape feel as ScoreboardPage. No header.

```
┌──────────────────────────────────────┐
│   RED SIDE (pairAName)               │   BLUE SIDE (pairBName)   │
│   big score, tap to +1, [−] button   │   big score, tap +1, [−]  │
├──────────────────────────────────────┤
│  [←]  [↺]  [⇄]        [Save Score]  │
└──────────────────────────────────────┘
```

- Red side: `bg-[#b91c1c]`, Blue side: `bg-[#1d4ed8]`
- Score: `clamp(6rem, 22vmax, 13rem)` white font-black, pop animation on change
- Pair name pinned to top-center of each side, faint uppercase
- `[−]` button: right edge of red side, left edge of blue side
- Footer: same ghost button style as ScoreboardPage

### Footer Buttons

| Button | Behaviour |
|--------|-----------|
| ← | Close overlay. If score differs from when overlay opened, show `confirm('Discard unsaved score?')` first |
| ↺ | Reset both scores to 0 |
| ⇄ | Swap scores and team sides |
| Save Score | Call `onSave(scoreA, scoreB)`, then call `onClose()` |

### localStorage

Each match gets its own key so scores never collide:

- `score-match-{matchId}-a` — side A score (number)
- `score-match-{matchId}-b` — side B score (number)

On mount: read from localStorage. On every change: write to localStorage.

### Navigation Guard

On `←` tap: if `(scoreA !== initialA || scoreB !== initialB)`, show `window.confirm('Discard unsaved score?')`. If user cancels, do nothing. If confirmed (or scores unchanged), call `onClose()`.

`initialA` / `initialB` are the scores read from localStorage on mount (i.e. whatever was there when the overlay opened).

## Integration in ScoreModal

`ScoreModal` already receives `match`, `pairAName`, `pairBName`, `onConfirm`, `onClose`.

Changes:
1. Add local state `showScoreboard: boolean`
2. Render `ScoreboardOverlay` when `showScoreboard === true`, passing:
   - `matchId={match.id}`
   - `pairAName` / `pairBName`
   - `onSave={(a, b) => { onConfirm(a, b); setShowScoreboard(false) }}`
   - `onClose={() => setShowScoreboard(false)}`
3. Add ghost button below "Confirm Score" button:
   ```tsx
   <button onClick={() => setShowScoreboard(true)} ...>
     🎯 Open Scoreboard
   </button>
   ```

## Match Row Tap Feedback

In `GroupMatches.tsx`, each match row `<button>` currently has `hover:bg-slate-700/50`. Add an active press state so the tap is visually confirmed on mobile:

```
active:bg-slate-600/60 active:scale-[0.98] transition-transform duration-75
```

This gives a brief scale-down + brightness pop when the row is tapped, consistent with how other tappable elements in the app behave.

## Files Changed

| File | Change |
|------|--------|
| `src/components/tournament/ScoreboardOverlay.tsx` | New component |
| `src/components/tournament/ScoreModal.tsx` | Add ghost button + render overlay |
| `src/components/tournament/GroupMatches.tsx` | Add `active:` tap feedback to match row buttons |
