import type { Player, ScheduleSlot, GameScore } from '../store'
import type { PlayerStanding } from '../utils/standings'
import { ordinal } from '../utils/ordinal'

interface GameRow {
  slot: number
  court: number
  partner: Player | undefined
  opponents: [Player | undefined, Player | undefined]
  scoreFor: number | null
  scoreAgainst: number | null
  won: boolean | null
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
      const partnerId = myTeam.find(id => id !== playerId) ?? ''
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


export default function PlayerMatchDetailSheet({ player, rank, schedule, gameScores, players, onClose }: Props) {
  if (!player) return null

  const games = getPlayerGames(player.player.id, schedule, gameScores, players)
  const diffLabel = player.diff > 0 ? `+${player.diff}` : String(player.diff)
  const diffColor = player.diff > 0 ? 'text-emerald-400' : player.diff < 0 ? 'text-red-400' : 'text-slate-400'
  const rankLabel = ordinal(rank)

  return (
    <div className="fixed inset-0 z-50 flex items-end" onClick={onClose} role="dialog" aria-modal="true" aria-label="Player match details">
      <div className="absolute inset-0 bg-black/60" />
      <div
        className="relative w-full bg-slate-900 rounded-t-3xl flex flex-col"
        style={{ maxHeight: '90%', boxShadow: '0 -8px 40px rgba(0,0,0,0.6)' }}
        onClick={e => e.stopPropagation()}
      >
        {/* Close row */}
        <div className="flex justify-end px-4 pt-3 pb-2 shrink-0">
          <button
            onClick={onClose}
            className="text-slate-400 active:text-slate-200 p-1 text-lg leading-none"
            aria-label="Close player details"
          >
            ✕
          </button>
        </div>

        {/* Summary header */}
        <div className="px-5 pt-1 pb-4 border-b border-slate-800 shrink-0">
          <div className="flex items-center gap-3">
            <div className="flex-1 min-w-0">
              <div className="text-[1rem] font-bold text-white truncate">{player.player.name}</div>
              <div className="text-[11px] text-slate-400 mt-0.5">{rankLabel} place</div>
            </div>
            <div className="flex gap-4">
              <div className="text-center">
                <div className="text-lg font-bold text-emerald-400">{player.wins}</div>
                <div className="text-[9px] text-slate-400 uppercase tracking-wide">W</div>
              </div>
              <div className="text-center">
                <div className="text-lg font-bold text-red-400">{player.losses}</div>
                <div className="text-[9px] text-slate-400 uppercase tracking-wide">L</div>
              </div>
              <div className="text-center">
                <div className={`text-lg font-bold ${diffColor}`}>{diffLabel}</div>
                <div className="text-[9px] text-slate-400 uppercase tracking-wide">Diff</div>
              </div>
            </div>
          </div>
        </div>

        {/* Game list */}
        <div className="flex-1 overflow-y-auto px-4 py-3 pb-8">
          {games.length === 0 ? (
            <p className="text-sm text-slate-400 text-center mt-8">No games found.</p>
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
                    <span className="text-[11px] text-slate-400 min-w-7 shrink-0">G{i + 1}</span>
                    <span className="flex-1 min-w-0 text-xs text-slate-400 truncate">
                      w/ <span className="text-slate-200">{partnerName}</span>
                      <span className="text-slate-400 mx-1">vs</span>
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
                      <span className="text-[11px] text-slate-400 shrink-0">–</span>
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
