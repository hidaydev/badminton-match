# Player Match Detail Sheet Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Tapping a player's name in the session leaderboard opens a 90%-height bottom sheet showing all their games in timeline order with partner, opponents, score, and W/L.

**Architecture:** New `PlayerMatchDetailSheet` component holds all sheet UI and game-derivation logic. `SummaryModal`'s `StandingsTab` adds a `selectedPlayer` state and passes it to the new component. No new utility files needed.

**Tech Stack:** React 19, TypeScript, Tailwind v4

---

### Task 1: Create `PlayerMatchDetailSheet` component

**Files:**
- Create: `src/components/PlayerMatchDetailSheet.tsx`

- [ ] **Step 1: Create the file with types and game-derivation logic**

```tsx
import type { Player, ScheduleSlot, GameScore } from '../store'
import type { PlayerStanding } from '../utils/standings'

interface GameRow {
  slot: number
  court: number
  partner: Player | undefined
  opponents: [Player | undefined, Player | undefined]
  scoreFor: number | null
  scoreAgainst: number | null
  won: boolean | null  // null = no score recorded
}

interface Props {
  player: PlayerStanding | null
  rank: number
  schedule: ScheduleSlot[]
  gameScores: Record<string, GameScore>
  players: Player[]
  onClose: () => void
}

function getPlayerGames(
  playerId: string,
  schedule: ScheduleSlot[],
  gameScores: Record<string, GameScore>,
  players: Player[],
): GameRow[] {
  const findPlayer = (id: string) => players.find(p => p.id === id)

  return schedule
    .filter(slot => slot.teamA.includes(playerId) || slot.teamB.includes(playerId))
    .sort((a, b) => a.slot - b.slot || a.court - b.court)
    .map(slot => {
      const inTeamA = slot.teamA.includes(playerId)
      const myTeam = inTeamA ? slot.teamA : slot.teamB
      const oppTeam = inTeamA ? slot.teamB : slot.teamA
      const partnerId = myTeam.find(id => id !== playerId)!
      const key = `${slot.slot}-${slot.court}`
      const score = gameScores[key] ?? null

      let scoreFor: number | null = null
      let scoreAgainst: number | null = null
      let won: boolean | null = null

      if (score) {
        scoreFor = inTeamA ? score.a : score.b
        scoreAgainst = inTeamA ? score.b : score.a
        won = scoreFor > scoreAgainst
      }

      return {
        slot: slot.slot,
        court: slot.court,
        partner: findPlayer(partnerId),
        opponents: [findPlayer(oppTeam[0]), findPlayer(oppTeam[1])],
        scoreFor,
        scoreAgainst,
        won,
      }
    })
}

function ordinal(n: number): string {
  const s = ['th', 'st', 'nd', 'rd']
  const v = n % 100
  return n + (s[(v - 20) % 10] ?? s[v] ?? s[0])
}

export default function PlayerMatchDetailSheet({ player, rank, schedule, gameScores, players, onClose }: Props) {
  if (!player) return null

  const games = getPlayerGames(player.player.id, schedule, gameScores, players)
  const diffLabel = player.diff > 0 ? `+${player.diff}` : String(player.diff)
  const diffColor = player.diff > 0 ? 'text-emerald-400' : player.diff < 0 ? 'text-red-400' : 'text-slate-400'
  const isPodium = rank <= 3
  const rankLabel = ordinal(rank)

  return (
    <div className="fixed inset-0 z-50 flex items-end" onClick={onClose}>
      <div className="absolute inset-0 bg-black/60" />
      <div
        className="relative w-full bg-slate-900 rounded-t-3xl flex flex-col"
        style={{ height: '90%', boxShadow: '0 -8px 40px rgba(0,0,0,0.6)' }}
        onClick={e => e.stopPropagation()}
      >
        {/* Drag handle */}
        <div className="flex justify-center pt-3 pb-1 shrink-0">
          <div className="w-10 h-1 bg-slate-700 rounded-full" />
        </div>

        {/* Summary header */}
        <div className="px-5 pt-3 pb-4 border-b border-slate-800 shrink-0">
          <div className="flex items-center gap-3">
            <div className="flex-1 min-w-0">
              <div className="text-base font-bold text-white truncate">{player.player.name}</div>
              <div className="text-[11px] text-slate-500 mt-0.5">{rankLabel} place</div>
            </div>
            <div className="flex gap-4">
              <div className="text-center">
                <div className="text-lg font-bold text-emerald-400">{player.wins}</div>
                <div className="text-[9px] text-slate-500 uppercase tracking-wide">W</div>
              </div>
              <div className="text-center">
                <div className="text-lg font-bold text-red-400">{player.losses}</div>
                <div className="text-[9px] text-slate-500 uppercase tracking-wide">L</div>
              </div>
              <div className="text-center">
                <div className={`text-lg font-bold ${diffColor}`}>{diffLabel}</div>
                <div className="text-[9px] text-slate-500 uppercase tracking-wide">Diff</div>
              </div>
            </div>
          </div>
        </div>

        {/* Game list */}
        <div className="flex-1 overflow-y-auto px-4 py-3">
          {games.length === 0 ? (
            <p className="text-sm text-slate-500 text-center mt-8">No games found.</p>
          ) : (
            <div className="flex flex-col gap-2">
              {games.map((g, i) => {
                const opp1 = g.opponents[0]?.name ?? '?'
                const opp2 = g.opponents[1]?.name ?? '?'
                const partnerName = g.partner?.name ?? '?'
                const hasScore = g.won !== null

                return (
                  <div
                    key={`${g.slot}-${g.court}`}
                    className={`flex items-center gap-2 px-3 py-2.5 rounded-xl border ${hasScore ? 'bg-slate-800/40 border-slate-700/30' : 'bg-slate-800/20 border-slate-800/20 opacity-50'}`}
                  >
                    <span className="text-[11px] text-slate-500 min-w-[26px] shrink-0">G{i + 1}</span>
                    <span className="flex-1 min-w-0 text-[12px] text-slate-400 truncate">
                      w/ <span className="text-slate-200">{partnerName}</span>
                      <span className="text-slate-600 mx-1">vs</span>
                      {opp1}, {opp2}
                    </span>
                    {hasScore ? (
                      <>
                        <span className={`text-[13px] font-bold shrink-0 ${g.won ? 'text-emerald-400' : 'text-red-400'}`}>
                          {g.scoreFor}–{g.scoreAgainst}
                        </span>
                        <span className={`text-[10px] px-1.5 py-0.5 rounded shrink-0 font-semibold ${g.won ? 'bg-emerald-950 text-emerald-400' : 'bg-red-950 text-red-400'}`}>
                          {g.won ? 'W' : 'L'}
                        </span>
                      </>
                    ) : (
                      <span className="text-[11px] text-slate-600 shrink-0">–</span>
                    )}
                  </div>
                )
              })}
            </div>
          )}
        </div>
      </div>
    </div>
  )
}
```

- [ ] **Step 2: Verify TypeScript compiles**

```bash
npm run build 2>&1 | head -30
```

Expected: no errors related to `PlayerMatchDetailSheet.tsx`

- [ ] **Step 3: Commit**

```bash
git add src/components/PlayerMatchDetailSheet.tsx
git commit -m "feat: add PlayerMatchDetailSheet component"
```

---

### Task 2: Wire up `StandingsTab` in `SummaryModal`

**Files:**
- Modify: `src/components/SummaryModal.tsx`

- [ ] **Step 1: Add import at top of `SummaryModal.tsx`**

After the existing imports (around line 19), add:

```tsx
import PlayerMatchDetailSheet from './PlayerMatchDetailSheet'
```

- [ ] **Step 2: Add `selectedPlayer` state to `StandingsTab`**

`StandingsTab` is the function starting at line 54. It currently receives `players`, `schedule`, `gameScores`, `absentPlayerIds` as props. Add state inside it, after the existing `absentList` and `standings` declarations:

```tsx
const [selectedPlayer, setSelectedPlayer] = useState<{ standing: typeof standings[number]; rank: number } | null>(null)
```

- [ ] **Step 3: Make the player name span clickable**

Find the player name `<span>` inside `standings.map` (around line 132):

```tsx
<span className={`flex-1 min-w-0 truncate ${isFirst ? 'text-sm font-bold text-emerald-300' : isPodium ? 'text-sm font-semibold text-emerald-100/80' : 'text-sm font-medium text-slate-400'}`}>
  {s.player.name}
</span>
```

Replace with:

```tsx
<span
  className={`flex-1 min-w-0 truncate cursor-pointer active:opacity-70 ${isFirst ? 'text-sm font-bold text-emerald-300' : isPodium ? 'text-sm font-semibold text-emerald-100/80' : 'text-sm font-medium text-slate-400'}`}
  onClick={() => setSelectedPlayer({ standing: s, rank })}
>
  {s.player.name}
</span>
```

- [ ] **Step 4: Render the sheet at the bottom of `StandingsTab`'s return**

Find the closing `</div>` of `StandingsTab`'s return (after the absent list, around line 153). Before it, add:

```tsx
      <PlayerMatchDetailSheet
        player={selectedPlayer?.standing ?? null}
        rank={selectedPlayer?.rank ?? 1}
        schedule={schedule}
        gameScores={gameScores}
        players={players}
        onClose={() => setSelectedPlayer(null)}
      />
```

- [ ] **Step 5: Verify build passes**

```bash
npm run build 2>&1 | head -30
```

Expected: no TypeScript errors

- [ ] **Step 6: Commit**

```bash
git add src/components/SummaryModal.tsx
git commit -m "feat: open player match detail sheet from leaderboard"
```

---

### Task 3: Manual verification

**Files:** none

- [ ] **Step 1: Start dev server**

```bash
npm run dev
```

- [ ] **Step 2: Open a session with scores entered**

Navigate to a session, enter scores for several games, open the Summary modal, go to the Leaderboard tab.

- [ ] **Step 3: Tap a player name**

Expected:
- 90%-height bottom sheet slides up from bottom
- Summary header shows player name, rank (e.g. "2nd place"), W / L / Diff stats
- Game list shows each game in order: `G1 w/ {partner} vs {opp1}, {opp2}  score  W/L badge`
- Games without scores show dimmed with `–`

- [ ] **Step 4: Tap the backdrop**

Expected: sheet closes

- [ ] **Step 5: Tap a different player**

Expected: sheet re-opens with new player's data

- [ ] **Step 6: Push to remote**

```bash
git push origin main
```
