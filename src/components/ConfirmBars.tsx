import type { Player, ScheduleSlot } from '../store'
import type { SwapTarget, TeamSwapTarget, ChangeTarget } from '../utils/swap'
import type { SlotSwapTarget } from '../utils/slotSwap'

interface ConfirmBarsProps {
  // Swap players
  pendingSwap: { t1: SwapTarget; t2: SwapTarget } | null
  onCancelSwap: () => void
  onConfirmSwap: () => void

  // Absent
  absentChanged: boolean
  absentPending: Set<string>
  onCancelAbsent: () => void
  onConfirmAbsent: () => void

  // Slot swap
  pendingSlotSwap: { g1: SlotSwapTarget; g2: SlotSwapTarget } | null
  onCancelSlotSwap: () => void
  onConfirmSlotSwap: () => void

  // Team swap
  pendingTeamSwap: { t1: TeamSwapTarget; t2: TeamSwapTarget } | null
  onCancelTeamSwap: () => void
  onConfirmTeamSwap: () => void

  // Change player
  pendingChange: { target: ChangeTarget; newName: string; b2b: boolean } | null
  onCancelChange: () => void
  onConfirmChange: () => void

  // Display data
  playerMap: Map<string, Player>
  schedule: ScheduleSlot[]
  saving: boolean
  courtLabel: (i: number) => string
}

export default function ConfirmBars({
  pendingSwap,
  onCancelSwap,
  onConfirmSwap,
  absentChanged,
  absentPending,
  onCancelAbsent,
  onConfirmAbsent,
  pendingSlotSwap,
  onCancelSlotSwap,
  onConfirmSlotSwap,
  pendingTeamSwap,
  onCancelTeamSwap,
  onConfirmTeamSwap,
  pendingChange,
  onCancelChange,
  onConfirmChange,
  playerMap,
  schedule,
  saving,
  courtLabel,
}: ConfirmBarsProps) {
  if (!pendingSwap && !absentChanged && !pendingSlotSwap && !pendingTeamSwap && !pendingChange) {
    return null
  }

  return (
    <>
      {/* Swap confirm bar */}
      {pendingSwap && (
        <div className="fixed bottom-0 left-0 right-0 z-50 bg-slate-950 border-t border-indigo-900/40 px-4 py-3">
          <div className="max-w-xl mx-auto">
          <div className="bg-indigo-950/50 border border-indigo-800/50 rounded-xl px-3 py-2.5 flex items-center gap-3">
            <div className="flex-1 min-w-0">
              <p className="text-xs font-semibold text-slate-200 truncate">
                <span className="text-indigo-200">{playerMap.get(pendingSwap.t1.playerId)?.name}</span>
                {' '}⇄{' '}
                <span className="text-indigo-200">{playerMap.get(pendingSwap.t2.playerId)?.name}</span>
              </p>
              <p className="text-[10px] text-red-400 mt-0.5">⚠ Cannot be undone</p>
            </div>
            <button
              onClick={onCancelSwap}
              className="text-xs text-slate-500 hover:text-slate-300 px-2 py-1.5 rounded-lg border border-slate-700 bg-slate-800/60 transition-colors shrink-0"
            >
              ✕
            </button>
            <button
              onClick={onConfirmSwap}
              disabled={saving}
              className="text-xs font-bold px-4 py-1.5 rounded-lg bg-indigo-600 hover:bg-indigo-500 text-white transition-colors disabled:opacity-50 shrink-0 flex items-center gap-1.5"
            >
              {saving && <svg className="animate-spin w-3 h-3 shrink-0" viewBox="0 0 24 24" fill="none"><circle className="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" strokeWidth="4" /><path className="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4z" /></svg>}
              {saving ? 'Saving…' : 'Confirm'}
            </button>
          </div>
          </div>
        </div>
      )}
      {/* Absent confirm bar */}
      {absentChanged && (
        <div className="fixed bottom-0 left-0 right-0 z-50 bg-slate-950 border-t border-red-900/40 px-4 py-3">
          <div className="max-w-xl mx-auto">
          <div className="bg-red-950/40 border border-red-800/50 rounded-xl px-3 py-2.5 flex items-center gap-3">
            <div className="flex-1 min-w-0">
              <p className="text-xs font-semibold text-slate-200 truncate">
                {absentPending.size === 0
                  ? 'Remove all absent tags'
                  : [...playerMap.values()].filter(p => absentPending.has(p.id)).map(p => p.name).join(', ')}
              </p>
              <p className="text-[10px] text-slate-500 mt-0.5">Excluded from leaderboard</p>
            </div>
            <button
              onClick={onCancelAbsent}
              className="text-xs text-slate-500 hover:text-slate-300 px-2 py-1.5 rounded-lg border border-slate-700 bg-slate-800/60 transition-colors shrink-0"
            >
              ✕
            </button>
            <button
              onClick={onConfirmAbsent}
              disabled={saving}
              className="text-xs font-bold px-4 py-1.5 rounded-lg bg-red-700 hover:bg-red-600 text-white transition-colors disabled:opacity-50 shrink-0 flex items-center gap-1.5"
            >
              {saving && <svg className="animate-spin w-3 h-3 shrink-0" viewBox="0 0 24 24" fill="none"><circle className="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" strokeWidth="4" /><path className="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4z" /></svg>}
              {saving ? 'Saving…' : 'Confirm'}
            </button>
          </div>
          </div>
        </div>
      )}
      {/* Slot swap confirm bar */}
      {pendingSlotSwap && (() => {
        const slotInfo = (t: { slot: number; court: number }) => {
          const game = schedule.find((g) => g.slot === t.slot && g.court === t.court)
          const label = `Slot ${t.slot + 1} - ${courtLabel(t.court)}`
          if (!game) return { label, players: '' }
          const aNames = game.teamA.map((id) => playerMap.get(id)?.name ?? id).join(' & ')
          const bNames = game.teamB.map((id) => playerMap.get(id)?.name ?? id).join(' & ')
          return { label, players: `${aNames} vs ${bNames}` }
        }
        const s1 = slotInfo(pendingSlotSwap.g1)
        const s2 = slotInfo(pendingSlotSwap.g2)
        return (
          <div className="fixed bottom-0 left-0 right-0 z-50 bg-slate-950 border-t border-orange-900/40 px-4 pt-3 pb-4">
            <div className="max-w-xl mx-auto flex flex-col gap-2.5">
              <div className="bg-orange-950/40 border border-orange-800/40 rounded-xl px-3 py-2.5 flex flex-col gap-1.5">
                <div className="flex items-start gap-2">
                  <div className="flex-1 min-w-0">
                    <span className="text-[10px] font-bold text-orange-400 uppercase tracking-wider">{s1.label}</span>
                    {s1.players && <p className="text-xs text-slate-200 leading-snug mt-0.5">{s1.players}</p>}
                  </div>
                </div>
                <div className="flex items-center gap-1.5">
                  <div className="h-px flex-1 bg-orange-900/40" />
                  <span className="text-[10px] text-orange-500 font-bold">↕ switch</span>
                  <div className="h-px flex-1 bg-orange-900/40" />
                </div>
                <div className="flex-1 min-w-0">
                  <span className="text-[10px] font-bold text-orange-400 uppercase tracking-wider">{s2.label}</span>
                  {s2.players && <p className="text-xs text-slate-200 leading-snug mt-0.5">{s2.players}</p>}
                </div>
              </div>
              <div className="flex items-center gap-2">
                <span className="text-[10px] text-red-400 flex-1">⚠ Cannot be undone</span>
                <button
                  onClick={onCancelSlotSwap}
                  className="text-xs text-slate-400 hover:text-slate-200 px-3 py-1.5 rounded-lg border border-slate-700 bg-slate-800/60 transition-colors shrink-0"
                >
                  Cancel
                </button>
                <button
                  onClick={onConfirmSlotSwap}
                  disabled={saving}
                  className="text-xs font-bold px-5 py-1.5 rounded-lg bg-orange-600 hover:bg-orange-500 text-white transition-colors disabled:opacity-50 shrink-0 flex items-center gap-1.5"
                >
                  {saving && <svg className="animate-spin w-3 h-3 shrink-0" viewBox="0 0 24 24" fill="none"><circle className="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" strokeWidth="4" /><path className="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4z" /></svg>}
                  {saving ? 'Saving…' : 'Confirm'}
                </button>
              </div>
            </div>
          </div>
        )
      })()}
      {/* Team swap confirm bar */}
      {pendingTeamSwap && (() => {
        const t1game = schedule.find(g => g.slot === pendingTeamSwap.t1.slot && g.court === pendingTeamSwap.t1.court)
        const t2game = schedule.find(g => g.slot === pendingTeamSwap.t2.slot && g.court === pendingTeamSwap.t2.court)
        const t1names = t1game
          ? (pendingTeamSwap.t1.team === 'A' ? t1game.teamA : t1game.teamB).map(id => playerMap.get(id)?.name ?? id).join(' & ')
          : '?'
        const t2names = t2game
          ? (pendingTeamSwap.t2.team === 'A' ? t2game.teamA : t2game.teamB).map(id => playerMap.get(id)?.name ?? id).join(' & ')
          : '?'
        return (
          <div className="fixed bottom-0 left-0 right-0 z-50 bg-slate-950 border-t border-violet-900/40 px-4 py-3">
            <div className="max-w-xl mx-auto">
              <div className="bg-violet-950/50 border border-violet-800/50 rounded-xl px-3 py-2.5 flex items-center gap-3">
                <div className="flex-1 min-w-0">
                  <p className="text-xs font-semibold text-slate-200 truncate">
                    <span className="text-violet-200">{t1names}</span>
                    {' '}⇄{' '}
                    <span className="text-violet-200">{t2names}</span>
                  </p>
                  <p className="text-[10px] text-red-400 mt-0.5">⚠ Cannot be undone</p>
                </div>
                <button
                  onClick={onCancelTeamSwap}
                  className="text-xs text-slate-500 hover:text-slate-300 px-2 py-1.5 rounded-lg border border-slate-700 bg-slate-800/60 transition-colors shrink-0"
                >
                  ✕
                </button>
                <button
                  onClick={onConfirmTeamSwap}
                  disabled={saving}
                  className="text-xs font-bold px-4 py-1.5 rounded-lg bg-violet-600 hover:bg-violet-500 text-white transition-colors disabled:opacity-50 shrink-0 flex items-center gap-1.5"
                >
                  {saving && <svg className="animate-spin w-3 h-3 shrink-0" viewBox="0 0 24 24" fill="none"><circle className="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" strokeWidth="4" /><path className="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4z" /></svg>}
                  {saving ? 'Saving…' : 'Confirm'}
                </button>
              </div>
            </div>
          </div>
        )
      })()}
      {/* Change player confirm bar */}
      {pendingChange && (() => {
        const game = schedule.find(g => g.slot === pendingChange.target.slot && g.court === pendingChange.target.court)
        const oldId = game?.[pendingChange.target.team === 'A' ? 'teamA' : 'teamB'][pendingChange.target.index] ?? ''
        const oldName = playerMap.get(oldId)?.name ?? oldId
        return (
          <div className="fixed bottom-0 left-0 right-0 z-50 bg-slate-950 border-t border-sky-900/40 px-4 pt-3 pb-4">
            <div className="max-w-xl mx-auto flex flex-col gap-2">
              <div className="bg-sky-950/40 border border-sky-800/40 rounded-xl px-3 py-2.5 flex items-center gap-3">
                <div className="flex-1 min-w-0">
                  <p className="text-xs font-semibold text-slate-200">
                    <span className="text-slate-400 line-through">{oldName}</span>
                    {' '}→{' '}
                    <span className="text-sky-300">{pendingChange.newName}</span>
                    <span className="text-slate-500 ml-1">Slot {pendingChange.target.slot + 1}, {courtLabel(pendingChange.target.court)}</span>
                  </p>
                  {pendingChange.b2b && (
                    <p className="text-[10px] text-amber-400 mt-0.5">⚠ {pendingChange.newName} plays back-to-back</p>
                  )}
                  <p className="text-[10px] text-red-400 mt-0.5">⚠ Cannot be undone</p>
                </div>
                <button
                  onClick={onCancelChange}
                  className="text-xs text-slate-500 hover:text-slate-300 px-2 py-1.5 rounded-lg border border-slate-700 bg-slate-800/60 transition-colors shrink-0"
                >
                  ✕
                </button>
                <button
                  onClick={onConfirmChange}
                  disabled={saving}
                  className="text-xs font-bold px-4 py-1.5 rounded-lg bg-sky-600 hover:bg-sky-500 text-white transition-colors disabled:opacity-50 shrink-0 flex items-center gap-1.5"
                >
                  {saving && <svg className="animate-spin w-3 h-3 shrink-0" viewBox="0 0 24 24" fill="none"><circle className="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" strokeWidth="4" /><path className="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4z" /></svg>}
                  {saving ? 'Saving…' : 'Confirm'}
                </button>
              </div>
            </div>
          </div>
        )
      })()}
    </>
  )
}
