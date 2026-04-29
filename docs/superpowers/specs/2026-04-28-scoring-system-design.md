# Scoring System Design

**Date:** 2026-04-28
**Status:** Approved

## Overview

Add score entry and a standings view to the badminton session app. Players can record numeric scores for each completed game directly in the Summary modal, and view an individual player standings table that updates live as scores are entered.

## Feature Summary

1. **Score entry** — an expandable inline panel in each game row of the Summary modal's Schedule tab
2. **Standings tab** — a second tab in the Summary modal showing ranked player standings

---

## Data Model

### New store field

Add `gameScores` to the Zustand store (`src/store/index.ts`):

```ts
gameScores: Record<string, { a: number; b: number }>
```

Key format: `"${slot}-${court}"` — the same string already used by `playedGames`.

Values: `a` = Team A's score, `b` = Team B's score (both integers ≥ 0).

### New store actions

```ts
setGameScore: (key: string, a: number, b: number) => void
clearGameScore: (key: string) => void
```

`setResult()` already resets `playedGames: []` on regenerate — it must also reset `gameScores: {}` for the same reason (the matchups change, so old scores are meaningless).

### Store version bump

Increment `version` from 10 → 11. The existing migration resets to defaults on any mismatch, which is correct.

---

## Score Entry UI

### Location

Inside `SummaryModal` (`src/pages/GeneratePage.tsx`), in the game row for each `ScheduleSlot`.

### Behaviour

- Every game row shows a faint `+ score` label on the right (visible even for unplayed games, but scores for unplayed games are valid — recording a score should also auto-mark the game as played).
- Tapping `+ score` expands an inline score panel below the game row header.
- Tapping again (the label becomes `▲ score` when open) collapses the panel.
- The panel shows two `<input type="number">` fields side by side, labelled with each team's player names (e.g. "Alice & Bob" / "Carol & Dan").
- Scores save to the store on `onBlur` of either input (no explicit save button needed).
- If a score is entered and the game is not yet marked as played, it is automatically added to `playedGames`.
- Once a score is saved, the collapsed row shows the score inline (e.g. `21–15`) in green next to the team names.
- Only one panel can be open at a time — opening a new one closes any previously open one.

### Validation

- Inputs accept integers 0–99 only.
- If either field is empty when the other is filled and the user blurs, do not save (leave score unset).
- Both fields must have a value to save.
- If both scores are equal, do not save (badminton always has a winner). Show a subtle inline error: *"Scores can't be equal."*

---

## Standings Tab

### Location

A second tab inside the `SummaryModal`, alongside the existing "Schedule" tab. The toolbar becomes:

```
[ Schedule ]  [ Standings ]        2/6 played
```

### Standings computation

Each `ScheduleSlot` with a saved score contributes to the individual stats of all 4 players in that game:

- **Wins:** players on the higher-scoring team get +1 win
- **Losses:** players on the lower-scoring team get +1 loss
- **Points For:** each player accumulates the score their team got
- **Points Against:** each player accumulates the score the opposing team got
- **Diff:** Points For − Points Against (can be negative)

Players with no scored games show 0-0 / 0 / 0.

### Columns

| # | Name | W-L | Diff | Pts |
|---|------|-----|------|-----|
| 1st | Alice | 2-0 | +12 | 42 |

- **#** — ordinal rank (1st, 2nd, 3rd, …)
- **Name** — player name
- **W-L** — wins and losses
- **Diff** — point differential (colour: green if positive, red if negative, neutral if 0)
- **Pts** — total points scored (Points For)

### Sort order

1. Most wins
2. Highest point diff (tiebreaker)
3. Highest total points scored (second tiebreaker)

### Visual treatment

- Rank 1 row: green-tinted background + gold rank label
- Rank 2 row: lighter green tint
- All other rows: standard slate background
- W-L text: green if wins > losses, red if losses > wins, neutral if equal

### Empty state

If no scores have been entered yet, show a centred message: *"Enter scores in the Schedule tab to see standings."*

---

## Component changes

### `SummaryModal`

- Add `activeTab: 'schedule' | 'standings'` local state, defaulting to `'schedule'`
- Add tab buttons in the toolbar
- Conditionally render `<ScheduleTab>` or `<StandingsTab>` based on `activeTab`
- Extract existing game list into `<ScheduleTab>` sub-component
- Add `<StandingsTab>` sub-component (new)
- Add `expandedScore: string | null` local state to track which game's score panel is open

### Store

- Add `gameScores`, `setGameScore`, `clearGameScore` as described above
- `setResult` resets `gameScores: {}`

---

## Out of scope

- Score history / audit log
- Editing scores after saving (overwriting is fine — just re-expand and retype)
- Standings on the shared URL view (read-only, no score entry)
- Per-game score display on the main `ScheduleView` (GeneratePage, outside the modal)
