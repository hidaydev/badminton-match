import type { Player, ScheduleSlot } from '../store'
import { computePlayerStats } from '../utils/playerStats'

interface PlayerStatsPanelProps {
  schedule: ScheduleSlot[]
  playerMap: Map<string, Player>
  absentPlayers: string[]
  standalone: boolean
}

export default function PlayerStatsPanel({
  schedule,
  playerMap,
  absentPlayers,
  standalone,
}: PlayerStatsPanelProps) {
  const absentSet = new Set(absentPlayers)

  if (standalone) {
    // Published session: include ALL players from schedule (not just playerMap)
    const schedulePlayerIds = new Set<string>()
    for (const g of schedule) {
      for (const id of [...g.teamA, ...g.teamB]) schedulePlayerIds.add(id)
    }
    const allPlayerIds = [...new Set([...playerMap.keys(), ...schedulePlayerIds])]
    if (allPlayerIds.length === 0 || schedule.length === 0) return null

    const playCount: Record<string, number> = Object.fromEntries(allPlayerIds.map(id => [id, 0]))
    for (const g of schedule) {
      for (const id of [...g.teamA, ...g.teamB]) playCount[id]++
    }

    // Sort: non-absent by play count desc, then absent at bottom
    const sorted = allPlayerIds.sort((a, b) => {
      const aAbsent = absentSet.has(a) ? 1 : 0
      const bAbsent = absentSet.has(b) ? 1 : 0
      if (aAbsent !== bAbsent) return aAbsent - bAbsent
      return (playCount[b] ?? 0) - (playCount[a] ?? 0)
    })

    return (
      <div className="mt-6 bg-surface border border-border-subtle rounded-2xl p-3 flex flex-col gap-2">
        <span className="text-sm font-semibold text-white">Player Stats</span>
        <div className="grid grid-cols-2 gap-y-2">
          {sorted.map((id) => {
            const p = playerMap.get(id)
            const name = p?.name ?? id
            const plays = playCount[id] ?? 0
            const isAbsent = absentSet.has(id)
            return (
              <div key={id} className={`flex items-center gap-1.5 ${isAbsent ? 'opacity-40' : ''}`}>
                <span className={`text-xs truncate ${isAbsent ? 'text-slate-400 line-through' : 'text-slate-300'}`}>{name}</span>
                {isAbsent && <span className="text-[10px] text-slate-300 bg-slate-800 rounded px-1 py-0.5 shrink-0">absent</span>}
                <span className={`text-xs font-bold shrink-0 ${isAbsent ? 'text-slate-400' : 'text-white'}`}>
                  {plays}×
                </span>
              </div>
            )
          })}
        </div>
      </div>
    )
  }

  // Generate page: original behavior with target plays
  const players = [...playerMap.values()]
  if (players.length === 0 || schedule.length === 0) return null

  const { playCount, sitCount, partnerWith, facedBy } = computePlayerStats(schedule, players.map(p => p.id))

  const idealPlays = (schedule.length * 4) / players.length

  return (
    <div className="mt-6 bg-surface border border-border-subtle rounded-2xl p-3 flex flex-col gap-2">
      <div className="flex items-center justify-between">
        <span className="text-sm font-semibold text-white">Player Stats</span>
        <span className="text-xs text-slate-400">target ~{idealPlays.toFixed(1)} plays</span>
      </div>
      <div className="grid grid-cols-1 gap-y-2">
        {players
          .sort((a, b) => (playCount[b.id] ?? 0) - (playCount[a.id] ?? 0))
          .map((p) => {
            const plays = playCount[p.id] ?? 0
            const sits = sitCount[p.id] ?? 0
            const partners = Object.keys(partnerWith[p.id] ?? {}).length
            const opponents = Object.keys(facedBy[p.id] ?? {}).length
            const over = plays > Math.ceil(idealPlays)
            const under = plays < Math.floor(idealPlays)
            return (
              <div key={p.id} className="flex items-center gap-2">
                <span className="text-xs text-slate-300 w-20 truncate">{p.name}</span>
                <span className={`text-xs font-bold w-8 ${over ? 'text-amber-400' : under ? 'text-sky-400' : 'text-emerald-400'}`}>
                  {plays}×
                </span>
                <span className="text-[10px] text-slate-400">
                  {sits} sit · {partners} P · {opponents} O
                </span>
              </div>
            )
          })}
      </div>
      <p className="text-[10px] text-slate-400">P = unique partners · O = unique opponents faced</p>
    </div>
  )
}
