import type { Player, ScheduleSlot } from '../../types'
import type { SwapTarget, TeamSwapTarget, ChangeTarget } from '../../utils/swap'
import type { SlotSwapTarget } from '../../utils/slotSwap'

type BarColor = 'indigo' | 'red' | 'orange' | 'violet' | 'sky'

const COLOR_MAP: Record<BarColor, { border: string; bg: string; btn: string; btnHover: string; accent: string }> = {
  indigo: { border: 'border-indigo-900/40', bg: 'bg-indigo-950/50 border-indigo-800/50', btn: 'bg-indigo-600', btnHover: 'hover:bg-indigo-500', accent: 'text-indigo-200' },
  red:    { border: 'border-red-900/40',    bg: 'bg-red-950/40 border-red-800/50',     btn: 'bg-red-700',    btnHover: 'hover:bg-red-600',    accent: 'text-red-300' },
  orange: { border: 'border-orange-900/40', bg: 'bg-orange-950/40 border-orange-800/40', btn: 'bg-orange-600', btnHover: 'hover:bg-orange-500', accent: 'text-orange-300' },
  violet: { border: 'border-violet-900/40', bg: 'bg-violet-950/50 border-violet-800/50', btn: 'bg-violet-600', btnHover: 'hover:bg-violet-500', accent: 'text-violet-200' },
  sky:    { border: 'border-sky-900/40',    bg: 'bg-sky-950/40 border-sky-800/40',     btn: 'bg-sky-600',    btnHover: 'hover:bg-sky-500',    accent: 'text-sky-300' },
}

const SPINNER = <svg className="animate-spin w-3 h-3 shrink-0" viewBox="0 0 24 24" fill="none"><circle className="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" strokeWidth="4" /><path className="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4z" /></svg>

function ConfirmActionBar({
  color,
  description,
  warning,
  extraWarning,
  onCancel,
  onConfirm,
  saving,
  children,
}: {
  color: BarColor
  description: React.ReactNode
  warning?: string
  extraWarning?: string
  onCancel: () => void
  onConfirm: () => void
  saving: boolean
  children?: React.ReactNode
}) {
  const c = COLOR_MAP[color]
  return (
    <div className={`fixed bottom-0 left-0 right-0 z-50 bg-ground border-t ${c.border} px-4 py-3`}>
      <div className="max-w-xl mx-auto">
        <div className={`${c.bg} border rounded-xl px-3 py-2.5`}>
          {children}
          <div className="flex items-center gap-3">
            <div className="flex-1 min-w-0">
              <div className="text-xs font-semibold text-slate-200 truncate">{description}</div>
              {warning && <p className="text-[10px] text-red-400 mt-0.5">⚠ {warning}</p>}
              {extraWarning && <p className="text-[10px] text-amber-400 mt-0.5">⚠ {extraWarning}</p>}
            </div>
            <button
              onClick={onCancel}
              className="text-xs text-slate-400 hover:text-slate-200 px-2 py-1.5 rounded-lg border border-slate-700 bg-slate-800/60 transition-colors shrink-0"
              aria-label="Cancel"
            >
              ✕
            </button>
            <button
              onClick={onConfirm}
              disabled={saving}
              className={`text-xs font-bold px-4 py-1.5 rounded-lg ${c.btn} ${c.btnHover} text-white transition-colors disabled:opacity-50 shrink-0 flex items-center gap-1.5`}
            >
              {saving && SPINNER}
              {saving ? 'Saving…' : 'Confirm'}
            </button>
          </div>
        </div>
      </div>
    </div>
  )
}

// ── Sub-components for each confirm bar ─────────────────────────────────────

function SlotSwapConfirmBar({
  pendingSlotSwap,
  schedule,
  playerMap,
  courtLabel,
  onCancel,
  onConfirm,
  saving,
}: {
  pendingSlotSwap: { g1: SlotSwapTarget; g2: SlotSwapTarget }
  schedule: ScheduleSlot[]
  playerMap: Map<string, Player>
  courtLabel: (i: number) => string
  onCancel: () => void
  onConfirm: () => void
  saving: boolean
}) {
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
    <ConfirmActionBar
      color="orange"
      description={
        <div className="flex flex-col gap-1.5">
          <div>
            <span className="text-[10px] font-bold text-orange-400 uppercase tracking-wider">{s1.label}</span>
            {s1.players && <p className="text-xs text-slate-200 leading-snug mt-0.5">{s1.players}</p>}
          </div>
          <div className="flex items-center gap-1.5">
            <div className="h-px flex-1 bg-orange-900/40" />
            <span className="text-[10px] text-orange-500 font-bold">↕ switch</span>
            <div className="h-px flex-1 bg-orange-900/40" />
          </div>
          <div>
            <span className="text-[10px] font-bold text-orange-400 uppercase tracking-wider">{s2.label}</span>
            {s2.players && <p className="text-xs text-slate-200 leading-snug mt-0.5">{s2.players}</p>}
          </div>
        </div>
      }
      warning="Cannot be undone"
      onCancel={onCancel}
      onConfirm={onConfirm}
      saving={saving}
    />
  )
}

function TeamSwapConfirmBar({
  pendingTeamSwap,
  schedule,
  playerMap,
  onCancel,
  onConfirm,
  saving,
}: {
  pendingTeamSwap: { t1: TeamSwapTarget; t2: TeamSwapTarget }
  schedule: ScheduleSlot[]
  playerMap: Map<string, Player>
  onCancel: () => void
  onConfirm: () => void
  saving: boolean
}) {
  const t1game = schedule.find(g => g.slot === pendingTeamSwap.t1.slot && g.court === pendingTeamSwap.t1.court)
  const t2game = schedule.find(g => g.slot === pendingTeamSwap.t2.slot && g.court === pendingTeamSwap.t2.court)
  const t1names = t1game
    ? (pendingTeamSwap.t1.team === 'A' ? t1game.teamA : t1game.teamB).map(id => playerMap.get(id)?.name ?? id).join(' & ')
    : '?'
  const t2names = t2game
    ? (pendingTeamSwap.t2.team === 'A' ? t2game.teamA : t2game.teamB).map(id => playerMap.get(id)?.name ?? id).join(' & ')
    : '?'

  return (
    <ConfirmActionBar
      color="violet"
      description={
        <>
          <span className="text-violet-200">{t1names}</span>
          {' '}⇄{' '}
          <span className="text-violet-200">{t2names}</span>
        </>
      }
      warning="Cannot be undone"
      onCancel={onCancel}
      onConfirm={onConfirm}
      saving={saving}
    />
  )
}

function ChangeConfirmBar({
  pendingChange,
  playerMap,
  courtLabel,
  onCancel,
  onConfirm,
  saving,
}: {
  pendingChange: { target: ChangeTarget; newName: string; b2b: boolean }
  playerMap: Map<string, Player>
  courtLabel: (i: number) => string
  onCancel: () => void
  onConfirm: () => void
  saving: boolean
}) {
  const oldName = playerMap.get(pendingChange.target.playerId)?.name ?? pendingChange.target.playerId

  return (
    <ConfirmActionBar
      color="sky"
      description={
        <>
          <span className="text-slate-400 line-through">{oldName}</span>
          {' '}→{' '}
          <span className="text-sky-300">{pendingChange.newName}</span>
          <span className="text-slate-400 ml-1">Slot {pendingChange.target.slot + 1}, {courtLabel(pendingChange.target.court)}</span>
        </>
      }
      warning="Cannot be undone"
      extraWarning={pendingChange.b2b ? `${pendingChange.newName} plays back-to-back` : undefined}
      onCancel={onCancel}
      onConfirm={onConfirm}
      saving={saving}
    />
  )
}

// ── Main component ──────────────────────────────────────────────────────────

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
      {pendingSwap && (
        <ConfirmActionBar
          color="indigo"
          description={
            <>
              <span className="text-indigo-200">{playerMap.get(pendingSwap.t1.playerId)?.name}</span>
              {' '}⇄{' '}
              <span className="text-indigo-200">{playerMap.get(pendingSwap.t2.playerId)?.name}</span>
            </>
          }
          warning="Cannot be undone"
          onCancel={onCancelSwap}
          onConfirm={onConfirmSwap}
          saving={saving}
        />
      )}

      {absentChanged && (
        <ConfirmActionBar
          color="red"
          description={
            absentPending.size === 0
              ? 'Remove all absent tags'
              : [...playerMap.values()].filter(p => absentPending.has(p.id)).map(p => p.name).join(', ')
          }
          warning="Excluded from leaderboard"
          onCancel={onCancelAbsent}
          onConfirm={onConfirmAbsent}
          saving={saving}
        />
      )}

      {pendingSlotSwap && (
        <SlotSwapConfirmBar
          pendingSlotSwap={pendingSlotSwap}
          schedule={schedule}
          playerMap={playerMap}
          courtLabel={courtLabel}
          onCancel={onCancelSlotSwap}
          onConfirm={onConfirmSlotSwap}
          saving={saving}
        />
      )}

      {pendingTeamSwap && (
        <TeamSwapConfirmBar
          pendingTeamSwap={pendingTeamSwap}
          schedule={schedule}
          playerMap={playerMap}
          onCancel={onCancelTeamSwap}
          onConfirm={onConfirmTeamSwap}
          saving={saving}
        />
      )}

      {pendingChange && (
        <ChangeConfirmBar
          pendingChange={pendingChange}
          playerMap={playerMap}
          courtLabel={courtLabel}
          onCancel={onCancelChange}
          onConfirm={onConfirmChange}
          saving={saving}
        />
      )}
    </>
  )
}
