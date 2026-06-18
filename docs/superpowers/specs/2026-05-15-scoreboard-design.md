# Scoreboard Feature — Design Spec

**Date:** 2026-05-15

## Overview

A full-screen, landscape-oriented scoreboard page for live badminton match scoring. Two sides (Red and Blue), tap to add a point, minus to subtract, reset and swap. Scores persist across refreshes via localStorage. No server save needed.

## Route & Navigation

- New route: `/scoreboard` under `HomeLayout`
- New card added to `HomePage` grid: icon `🎯`, label `Scoreboard`, description `Live match scoring`

## Page: ScoreboardPage

Single file: `src/pages/ScoreboardPage.tsx`

### Layout

Full viewport (`w-screen h-screen`), forced landscape feel via a horizontal flex layout:

```
┌─────────────────┬─────────────────┐
│                 │                 │
│   RED SIDE      │   BLUE SIDE     │
│   (tap = +1)    │   (tap = +1)    │
│                 │                 │
│     [−]         │         [−]     │
├────────────────────────────────────┤
│       [↺ Reset]   [⇄ Swap]        │
└────────────────────────────────────┘
```

- Each side fills 50% width, full height minus bottom bar
- Clicking/tapping anywhere on the side adds 1 point
- `−` button is positioned at bottom of each side, stops propagation so it doesn't also trigger +1
- Bottom action bar (48px): Reset | Swap centered

### Styling

Matches app dark slate theme:
- Red side: `bg-red-900` (`#7f1d1d`)
- Blue side: `bg-blue-900` (`#1e3a8a`)
- Score number: `text-white font-black` at `text-[clamp(6rem,22vw,14rem)]`
- Team label: small uppercase, muted white
- "tap to score" hint: very faint
- Divider: 1px vertical line, semi-transparent
- Bottom bar: `bg-black/35` with subtle top border
- Action buttons: ghost style, muted white

### Score pop animation

Brief scale pop (keyframe) on the score number each time it changes.

## State

Pure `useState` in the component — no Zustand store.

localStorage keys:
- `score-red` — number
- `score-blue` — number

On mount: read from localStorage. On every change: write to localStorage.

## Interactions

| Action | Result |
|--------|--------|
| Tap Red side | `red++` |
| Tap Blue side | `blue++` |
| Tap `−` (red) | `red = Math.max(0, red - 1)` |
| Tap `−` (blue) | `blue = Math.max(0, blue - 1)` |
| Tap Reset | `red = 0, blue = 0` |
| Tap Swap | `[red, blue] = [blue, red]` |

No maximum score. Score cannot go below 0.

## Files Changed

| File | Change |
|------|--------|
| `src/pages/ScoreboardPage.tsx` | New file |
| `src/App.tsx` | Import + add route `/scoreboard` under HomeLayout |
| `src/pages/HomePage.tsx` | Add Scoreboard card to the 2×2 grid |
