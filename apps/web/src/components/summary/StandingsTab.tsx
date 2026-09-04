import { useState } from 'react'
import type { Player, GameScore, ScheduleSlot } from '../../types'
import { computeStandings } from '../../utils/standings'
import { isPlaceholderName } from '../../utils/placeholders'
import { ordinal } from '../../utils/ordinal'
import PlayerMatchDetailSheet from './PlayerMatchDetailSheet'

interface StandingsTabProps {
  players: Player[]
  schedule: ScheduleSlot[]
  gameScores: Record<string, GameScore>
  absentPlayerIds: string[]
  skippedPlayers?: Record<string, string[]>
}

export default function StandingsTab({
  players,
  schedule,
  gameScores,
  absentPlayerIds,
  skippedPlayers = {},
}: StandingsTabProps) {
  const absentList = players.filter(p => absentPlayerIds.includes(p.id))
  const placeholderList = players.filter(p => isPlaceholderName(p.name))
  // VOID = absent + placeholder (game yang memuat keduanya tidak ditallikan)
  const voidPlayerIds = [...absentPlayerIds, ...placeholderList.map(p => p.id)]
  const standings = computeStandings(
    players.filter(p => !absentPlayerIds.includes(p.id) && !isPlaceholderName(p.name)),
    schedule,
    gameScores,
    voidPlayerIds,
    skippedPlayers,
  )
  const [selectedPlayer, setSelectedPlayer] = useState<{ standing: typeof standings[number]; rank: number } | null>(null)
  const hasScores = Object.keys(gameScores).length > 0

  if (!hasScores) {
    return (
      <div className="flex flex-col gap-4">
        <div className="flex items-center justify-center min-h-50">
          <p className="text-sm text-slate-400 text-center">Enter scores in the Schedule tab to see leaderboard.</p>
        </div>
        {(absentList.length > 0 || placeholderList.length > 0) && (
          <div className="flex flex-col gap-1.5">
            <p className="text-[10px] font-bold text-slate-400 uppercase tracking-wider px-2">Not playing</p>
            {absentList.map(p => (
              <div key={p.id} className="flex items-center gap-2 pl-2 pr-2 py-2 rounded-xl border border-slate-800/50 bg-slate-800/20">
                <span className="flex-1 text-sm font-medium text-slate-400 line-through">{p.name}</span>
                <span className="text-[10px] text-slate-400">absent</span>
              </div>
            ))}
            {placeholderList.map(p => (
              <div key={p.id} className="flex items-center gap-2 pl-2 pr-2 py-2 rounded-xl border border-slate-800/50 bg-slate-800/20">
                <span className="flex-1 text-sm font-medium text-slate-400">{p.name}</span>
                <span className="text-[10px] text-slate-400">tbd</span>
              </div>
            ))}
          </div>
        )}
      </div>
    )
  }

  return (
    <div className="flex flex-col gap-1.5">
      {/* Tiebreaker order strip — hugs top divider */}
      <div className="flex justify-end gap-1 items-center pl-2 pr-2 -mt-4 pt-1 pb-3 text-[8px] text-slate-400">
        <span>ranked by:</span>
        <span className="font-semibold">W-L</span>
        <span>›</span>
        <span className="font-semibold">Diff</span>
        <span>›</span>
        <span className="font-semibold">Pts</span>
        <span>›</span>
        <span className="font-semibold">A-Z</span>
      </div>
      {/* Header */}
      <div className="flex items-center gap-2 pl-2 pr-2 mb-1">
        <span className="w-8 text-[10px] font-bold text-slate-400 text-center shrink-0">#</span>
        <span className="flex-1 text-[10px] font-bold text-slate-400">Name</span>
        <span className="w-11 text-[10px] font-bold text-slate-400 text-center shrink-0">W-L</span>
        <span className="w-9 text-[10px] font-bold text-slate-400 text-center shrink-0">Diff</span>
        <span className="w-9 text-[10px] font-bold text-slate-400 text-center shrink-0">Pts</span>
      </div>

      {standings.map((s, i) => {
        const rank = i + 1
        const isFirst = rank === 1
        const isSecond = rank === 2
        const isThird = rank === 3
        const isPodium = isFirst || isSecond || isThird
        const wlColor = s.wins > s.losses ? 'text-emerald-400' : s.losses > s.wins ? 'text-red-400' : 'text-slate-400'
        const diffColor = s.diff > 0 ? 'text-emerald-400' : s.diff < 0 ? 'text-red-400' : 'text-slate-400'
        const diffLabel = s.diff > 0 ? `+${s.diff}` : String(s.diff)

        const medal = isFirst ? 'gold' : isSecond ? 'silver' : isThird ? 'bronze' : null

        const rowBg = isPodium
          ? 'bg-emerald-950/45 border-emerald-800/35'
          : 'bg-slate-800/30 border-slate-700/20'

        const rankCls =
          medal === 'gold' ? 'text-accent' : medal === 'silver' ? 'text-slate-200' : medal === 'bronze' ? 'text-slate-400' : 'text-slate-400'

        return (
          <div
            key={s.player.id}
            className={`flex items-center gap-2 pl-2 pr-2 py-2.5 rounded-xl border ${rowBg}`}
          >
            <div className="w-8 flex justify-center shrink-0">
              <span className={`text-[11px] font-bold font-sans ${rankCls}`}>{ordinal(rank)}</span>
            </div>
            <span
              className={`flex-1 min-w-0 truncate cursor-pointer active:opacity-70 ${isFirst ? 'text-sm font-bold text-emerald-300' : isPodium ? 'text-sm font-semibold text-emerald-100/80' : 'text-sm font-medium text-slate-400'}`}
              onClick={() => setSelectedPlayer({ standing: s, rank })}
            >
              {s.player.name}
            </span>
            <span className={`w-11 text-[11px] font-semibold text-center shrink-0 ${wlColor}`}>{s.wins}-{s.losses}</span>
            <span className={`w-9 text-[11px] font-semibold text-center shrink-0 ${diffColor}`}>{diffLabel}</span>
            <span className="w-9 text-[11px] font-semibold text-center shrink-0 text-slate-400">{s.pointsFor}</span>
          </div>
        )
      })}
      {(absentList.length > 0 || placeholderList.length > 0) && (
        <>
          <div className="h-px bg-slate-800 my-1" />
          <p className="text-[10px] font-bold text-slate-400 uppercase tracking-wider px-2 mt-1">Not playing</p>
          {absentList.map(p => (
            <div key={p.id} className="flex items-center gap-2 pl-2 pr-2 py-2 rounded-xl border border-slate-800/50 bg-slate-800/20">
              <span className="flex-1 text-sm font-medium text-slate-400 line-through">{p.name}</span>
              <span className="text-[10px] text-slate-400">absent</span>
            </div>
          ))}
          {placeholderList.map(p => (
            <div key={p.id} className="flex items-center gap-2 pl-2 pr-2 py-2 rounded-xl border border-slate-800/50 bg-slate-800/20">
              <span className="flex-1 text-sm font-medium text-slate-400">{p.name}</span>
              <span className="text-[10px] text-slate-400">tbd</span>
            </div>
          ))}
        </>
      )}
      <PlayerMatchDetailSheet
        player={selectedPlayer?.standing ?? null}
        rank={selectedPlayer?.rank ?? 1}
        schedule={schedule}
        gameScores={gameScores}
        players={players}
        voidPlayerIds={voidPlayerIds}
        skippedPlayers={skippedPlayers}
        onClose={() => setSelectedPlayer(null)}
      />
    </div>
  )
}
