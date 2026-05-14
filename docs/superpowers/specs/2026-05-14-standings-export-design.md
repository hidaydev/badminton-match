# Standings Export — Instagram Post & Story

**Date:** 2026-05-14

## Overview

Add two new export options to the Instagram Post page's download sheet: **Standing Post** (1080×1350) and **Standing Story** (1080×1920). Both render a top-10 player leaderboard from a user-selected cloud session, with no photo required.

---

## Download Sheet Changes

The bottom sheet becomes a 2×2 grid:

| Row | Left | Right |
|-----|------|-------|
| 1 | Post (existing photo export) | Story (existing photo export) |
| 2 | Standing Post (new) | Standing Story (new) |

Tapping a standing option transitions the sheet to a session picker screen (same modal, replaced content). A back chevron returns to the format grid.

---

## Session Picker Flow

1. User taps "Standing Post" or "Standing Story"
2. Sheet content replaced with a scrollable session list fetched via `useListSessions`
3. Each row: date + session title + player count
4. User taps a session → loading spinner shown
5. Full session fetched via `useGetSession(id)` → `computeStandings()` called with session's players, schedule, gameScores
6. Offscreen canvas rendered → blob created → download triggered
7. Sheet closes on success

---

## Canvas Rendering

Both formats share a new `drawStandings()` canvas function.

### Standing Post (1080×1350)
- Background: `#1e293b` (dark slate fill)
- Top: `drawHeader()` with logo band (reuse existing)
- Bottom: footer PNG (reuse existing)
- No user photo, no date graphic

### Standing Story (1080×1920)
- Background: `story-bg.png` full-bleed
- Top: `drawHeader()` with logo band
- Bottom: footer PNG
- No user photo, no date graphic

### Standings Content (shared)
Vertically centered in the space between header and footer:

- **Session info line**: date + title, small mono text, slate color
- **Subtitle**: "Top 10 of N players", small, above the list
- **10 rows**, evenly spaced:
  - Rank number — gold (`#F5B400`) for top 3, white for 4–10
  - Player name — bold white
  - W / L — yellow wins, slate-400 losses
  - Point diff — `+XX` yellow or `-XX` slate-400
- Thin separator lines between rows

---

## Data Flow

```
useListSessions()          → session list in picker
useGetSession(id)          → CloudSnapshot (players, schedule, gameScores)
computeStandings(...)      → PlayerStanding[] sorted by wins → diff → pointsFor
slice(0, 10)               → top 10
drawStandingsCanvas(...)   → offscreen HTMLCanvasElement
canvas.toBlob(...)         → triggerDownload()
```

`computeStandings` already exists in `src/utils/standings.ts` — no changes needed.

---

## Component State Additions

```ts
type StandingMode = 'post' | 'story' | null
const [standingMode, setStandingMode] = useState<StandingMode>(null)
const [sheetScreen, setSheetScreen] = useState<'formats' | 'session-picker'>('formats')
const [selectedSessionId, setSelectedSessionId] = useState<string | null>(null)
```

The existing `showDownloadSheet` boolean controls sheet visibility. `sheetScreen` controls which content is shown inside it.

---

## Files Changed

- `src/pages/InstagramPostPage.tsx` — add standing download handlers, session picker UI, `drawStandings()` function, updated download sheet layout
- No new files required
