import type { Player, MatchConstraint } from '../../types'
import { PLAYERS_PER_GAME } from '../../types'
import { useStore } from '../../store'
import { selectTotalGames } from '../../store/selectors'
import { useValidation } from './useValidation'

export function ValidationPanel({ players, matches }: { players: Player[]; matches: MatchConstraint[] }) {
  const session = useStore((s) => s.session)
  const { tooManyTotal, effectiveSlotsNeeded, overloadedPlayers, pinnedConflicts, singlePlayerPairs } = useValidation(players, matches)
  const expectedPlays = players.length > 0
    ? Math.round((selectTotalGames(session) * PLAYERS_PER_GAME) / players.length)
    : 0

  const counts: Record<string, number> = {}
  for (const m of matches) {
    for (const id of m.slots) {
      if (id) counts[id] = (counts[id] ?? 0) + 1
    }
  }

  if (matches.length === 0 || players.length === 0) return null

  return (
    <div className="flex flex-col gap-2">
      {/* Total fix matches check */}
      {tooManyTotal && (
        <div className="flex items-start gap-2 p-3 bg-red-900/30 border border-red-700 rounded-xl text-red-400 text-sm">
          <span>⚠</span>
          <span>
            {effectiveSlotsNeeded} game slots needed for fix matches but only {selectTotalGames(session)} available — {effectiveSlotsNeeded - selectTotalGames(session)} can't be placed.
          </span>
        </div>
      )}

      {/* Per-player overload */}
      {overloadedPlayers.length > 0 && (
        <div className="flex flex-col gap-1 p-3 bg-red-900/30 border border-red-700 rounded-xl">
          <span className="text-red-400 text-sm font-medium">⚠ Players scheduled in too many fix matches:</span>
          {overloadedPlayers.map(({ player, count, max }) => (
            <span key={player.id} className="text-xs text-red-300 pl-4">
              {player.name} — {count} fix matches but max {max} slots available
            </span>
          ))}
        </div>
      )}

      {/* Pinned conflicts */}
      {pinnedConflicts.size > 0 && (
        <div className="flex flex-col gap-1 p-3 bg-red-900/30 border border-red-700 rounded-xl">
          <span className="text-red-400 text-sm font-medium">⚠ Pinned match conflicts:</span>
          {[...pinnedConflicts.entries()].map(([idx, msgs]) => (
            <div key={idx} className="flex flex-col gap-0.5 pl-4">
              <span className="text-xs text-red-300 font-medium">Match #{idx + 1}:</span>
              {msgs.map((msg, i) => (
                <span key={i} className="text-xs text-red-300/80 pl-2">· {msg}</span>
              ))}
            </div>
          ))}
        </div>
      )}

      {/* Single-player pair warning */}
      {singlePlayerPairs.length > 0 && (
        <div className="p-3 bg-amber-900/30 border border-amber-700 rounded-xl text-amber-400 text-sm">
          <p className="font-medium">⚠ {singlePlayerPairs.length} fix match(es) have only 1 player on a side:</p>
          <ul className="mt-1 text-xs">
            {singlePlayerPairs.map(({ match, side }, i) => (
              <li key={i}>Match #{matches.indexOf(match) + 1}: Side {side} has only 1 player specified</li>
            ))}
          </ul>
        </div>
      )}

      {/* Per-player counts */}
      <div className="bg-surface border border-border-subtle rounded-2xl p-3 flex flex-col gap-2">
        <div className="flex flex-col gap-0.5">
          <span className="text-sm font-semibold text-white">Fix Match Assignments</span>
          <span className="text-xs text-slate-400">max {expectedPlays}x per player (balanced)</span>
        </div>
        <div className="flex flex-col gap-1.5">
          {players.map((p) => {
            const count = counts[p.id] ?? 0
            const over = count > expectedPlays
            const pct = Math.min((count / expectedPlays) * 100, 100)
            return (
              <div key={p.id} className="flex items-center gap-2">
                <span className={`w-24 text-xs truncate ${over ? 'text-red-400' : count > 0 ? 'text-slate-300' : 'text-slate-400'}`}>{p.name}</span>
                <div className="flex-1 h-1.5 bg-slate-800 rounded-full overflow-hidden">
                  <div
                    className={`h-full rounded-full transition-all ${over ? 'bg-red-500' : count > 0 ? 'bg-indigo-500' : 'bg-slate-700'}`}
                    style={{ width: `${pct}%` }}
                  />
                </div>
                <span className={`text-xs w-14 text-right ${over ? 'text-red-400 font-semibold' : count > 0 ? 'text-slate-400' : 'text-slate-400'}`}>
                  {count}/{expectedPlays}{over ? ' ⚠' : ''}
                </span>
              </div>
            )
          })}
        </div>
      </div>
    </div>
  )
}
