import type { Player, ScheduleSlot, GameScore, PlayerId } from '../../types'
import { toPlayerId, toGameKey } from '../../types'
import type { PlayerStanding } from '../../utils/standings'
import { ordinal } from '../../utils/ordinal'

interface GameRow {
  slot: number
  court: number
  partner: Player | undefined
  opponents: [Player | undefined, Player | undefined]
  scoreFor: number | null
  scoreAgainst: number | null
  won: boolean | null
}

interface PlayerMatchDetailSheetProps {
  player: PlayerStanding | null
  rank: number
  schedule: ScheduleSlot[]
  gameScores: Record<string, GameScore>
  players: Player[]
  onClose: () => void
}

function buildGameRows(
  playerId: string,
  schedule: ScheduleSlot[],
  gameScores: Record<string, GameScore>,
  players: Player[],
): GameRow[] {
  const pid = toPlayerId(playerId)
  const findPlayer = (id: PlayerId) => players.find(p => p.id === id)

  return schedule
    .filter(slot => slot.teamA.includes(pid) || slot.teamB.includes(pid))
    .sort((a, b) => a.slot - b.slot || a.court - b.court)
    .map(slot => {
      const inTeamA = slot.teamA.includes(pid)
      const myTeam = inTeamA ? slot.teamA : slot.teamB
      const oppTeam = inTeamA ? slot.teamB : slot.teamA
      const partnerId = myTeam.find(id => id !== pid) ?? toPlayerId('')
      const key = toGameKey(slot.slot, slot.court)
      const score = gameScores[key]

      return {
        slot: slot.slot,
        court: slot.court,
        partner: findPlayer(partnerId),
        opponents: [findPlayer(oppTeam[0]), findPlayer(oppTeam[1])],
        scoreFor: score ? (inTeamA ? score.a : score.b) : null,
        scoreAgainst: score ? (inTeamA ? score.b : score.a) : null,
        won: score ? (inTeamA ? score.a > score.b : score.b > score.a) : null,
      }
    })
}

export default function PlayerMatchDetailSheet({
  player,
  rank,
  schedule,
  gameScores,
  players,
  onClose,
}: PlayerMatchDetailSheetProps) {
  if (!player) return null

  const games = buildGameRows(player.player.id, schedule, gameScores, players)

  return (
    <div className="fixed inset-0 z-50 flex items-end justify-center bg-black/50" onClick={onClose}>
      <div
        className="bg-slate-900 rounded-t-2xl w-full max-w-lg overflow-y-auto p-4"
        style={{ maxHeight: '80vh' }}
        onClick={e => e.stopPropagation()}
      >
        <div className="flex items-center justify-between mb-4">
          <div>
            <h2 className="text-lg font-semibold text-slate-100">{player.player.name}</h2>
            <p className="text-sm text-slate-400">#{rank} {ordinal(rank)}</p>
          </div>
          <button
            onClick={onClose}
            className="p-2 text-slate-400 hover:text-slate-200 transition-colors"
            aria-label="Close"
          >
            ✕
          </button>
        </div>

        <div className="grid grid-cols-3 gap-3 mb-4">
          <div className="bg-slate-800 rounded-lg p-3 text-center">
            <div className="text-2xl font-bold text-slate-100">{player.wins}</div>
            <div className="text-xs text-slate-400">Won</div>
          </div>
          <div className="bg-slate-800 rounded-lg p-3 text-center">
            <div className="text-2xl font-bold text-slate-100">{player.losses}</div>
            <div className="text-xs text-slate-400">Lost</div>
          </div>
          <div className="bg-slate-800 rounded-lg p-3 text-center">
            <div className="text-2xl font-bold text-slate-100">{player.wins + player.losses}</div>
            <div className="text-xs text-slate-400">Played</div>
          </div>
        </div>

        <h3 className="text-sm font-medium text-slate-300 mb-2">Match History</h3>
        {games.length === 0 ? (
          <p className="text-sm text-slate-500">No games played yet.</p>
        ) : (
          <div className="space-y-2">
            {games.map((game, i) => (
              <div key={i} className="bg-slate-800 rounded-lg p-3">
                <div className="flex items-center justify-between mb-1">
                  <span className="text-xs text-slate-400">
                    Game {game.slot + 1} • Court {game.court + 1}
                  </span>
                  {game.won !== null && (
                    <span className={`text-xs font-medium ${game.won ? 'text-emerald-400' : 'text-red-400'}`}>
                      {game.won ? 'Won' : 'Lost'}
                    </span>
                  )}
                </div>
                <div className="flex items-center gap-2">
                  <span className="text-sm text-slate-200">
                    {game.partner?.name ?? '?'}
                  </span>
                  <span className="text-xs text-slate-500">vs</span>
                  <span className="text-sm text-slate-200">
                    {game.opponents[0]?.name ?? '?'} & {game.opponents[1]?.name ?? '?'}
                  </span>
                </div>
                {game.scoreFor !== null && (
                  <div className="text-sm text-slate-300 mt-1">
                    {game.scoreFor} - {game.scoreAgainst}
                  </div>
                )}
              </div>
            ))}
          </div>
        )}
      </div>
    </div>
  )
}
