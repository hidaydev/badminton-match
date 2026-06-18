# Player Match Detail Sheet

**Date:** 2026-06-18  
**Status:** Approved

## Overview

Tapping a player's name in the session leaderboard opens a bottom sheet showing all games that player participated in, in timeline order, with partner, opponents, score, and win/loss result.

## Component

**New file:** `src/components/PlayerMatchDetailSheet.tsx`

### Props

```ts
interface PlayerMatchDetailSheetProps {
  player: PlayerStanding | null   // null = sheet hidden
  rank: number                    // leaderboard position (1-based)
  schedule: ScheduleSlot[]
  gameScores: Record<string, GameScore>
  players: Player[]               // full player list for name lookup
  onClose: () => void
}
```

When `player` is null the component renders nothing.

## Sheet Layout

- **Overlay:** `fixed inset-0 z-50` — tapping the backdrop (`bg-black/60`) calls `onClose`
- **Panel:** anchored to bottom, `rounded-t-3xl`, `h-[90%]`, `bg-slate-900`, scrollable content
- **Drag handle:** `w-10 h-1 bg-slate-700 rounded-full mx-auto` at top

### Summary Header

Displayed at the top of the sheet, above the game list:

| Element | Detail |
|---|---|
| Player name | Large, bold |
| Rank pill | e.g. "3rd" — amber/emerald depending on podium |
| W stat | Green |
| L stat | Red |
| Diff stat | Green if positive, red if negative |

### Game List

Scrollable list below the header. Each entry is one game the player participated in, ordered by slot number ascending.

**Row layout (compact single line):**

```
G{slot}  w/ {partner}  vs  {opp1}, {opp2}   {scoreA}–{scoreB}   [W] or [L]
```

- `G{slot}` — game number label in muted slate
- Partner name highlighted in white; opponent names in slate-400
- Score coloured green (win) or red (loss)
- W/L badge: green bg for win, red bg for loss
- Games with no score recorded shown dimmed with "–" in score column and no badge

### Empty State

If the player has no games in the schedule (shouldn't happen normally), show a centered "No games found" message.

## SummaryModal Changes

File: `src/components/SummaryModal.tsx` — minimal changes to the `StandingsTab` inner component:

1. Add state: `const [selectedPlayer, setSelectedPlayer] = useState<{ standing: PlayerStanding; rank: number } | null>(null)`
2. Player name `<span>` in each row gains `cursor-pointer` and `onClick={() => setSelectedPlayer({ standing: s, rank })}`
3. Render `<PlayerMatchDetailSheet>` at the bottom of the `StandingsTab` return, passing all required props

## Helper Logic

Inside `PlayerMatchDetailSheet`, a local function `getPlayerGames` computes the game list:

```ts
function getPlayerGames(playerId, schedule, gameScores, players):
  filter schedule slots where playerId in teamA or teamB
  sort by slot ascending
  for each slot:
    key = `${slot.slot}-${slot.court}`
    score = gameScores[key]
    partner = other player in same team
    opponents = players in opposing team
    won = (in teamA && score.a > score.b) || (in teamB && score.b > score.a)
  return array of game rows
```

No new utility file needed — this logic is local to the component.

## Visual Style

Follows existing bottom sheet pattern from `InstagramPostPage.tsx`:
- `fixed inset-0 z-50 flex items-end`
- `bg-black/60` backdrop
- `rounded-t-3xl` panel with `box-shadow: 0 -8px 40px rgba(0,0,0,0.6)`
- Dark slate theme consistent with the rest of the app
