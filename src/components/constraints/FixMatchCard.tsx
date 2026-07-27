import type { Player, MatchConstraint } from '../../types'
import { toPlayerId, toTimeString } from '../../types'
import { useStore } from '../../store'
import { computeTimeSlots, courtsAtTime } from '../../utils/time'
import { SlotPicker } from './SlotPicker'

// ── Fix Match card ────────────────────────────────────────────────────────────
export function FixMatchCard({
  match,
  index,
  players,
  conflicts,
}: {
  match: MatchConstraint
  index: number
  players: Player[]
  conflicts: string[]
}) {
  const updateFixMatch = useStore((s) => s.updateFixMatch)
  const duplicateFixMatch = useStore((s) => s.duplicateFixMatch)
  const removeFixMatch = useStore((s) => s.removeFixMatch)
  const session = useStore((s) => s.session)
  const timeSlots = computeTimeSlots(session)
  const availableCourts = match.mode === 'pinned' && match.pinnedTime ? courtsAtTime(session, match.pinnedTime) : []

  const [A1, A2, B1, B2] = match.slots
  const used = [A1, A2, B1, B2].filter(Boolean)

  function setSlot(i: 0 | 1 | 2 | 3, val: string) {
    const next = [...match.slots] as MatchConstraint['slots']
    next[i] = toPlayerId(val)
    updateFixMatch(match.id, { slots: next })
  }

  function describe() {
    const name = (id: string) => players.find((p) => p.id === id)?.name ?? '?'
    const teamA = [A1, A2].filter(Boolean)
    const teamB = [B1, B2].filter(Boolean)
    if (teamA.length === 0 && teamB.length === 0) return null
    const side = (ids: string[]) => ids.length === 0 ? 'anyone' : ids.map(name).join(' + ')
    if (teamA.length > 0 && teamB.length === 0) return `${side(teamA)} paired together — opponents open`
    if (teamA.length === 0 && teamB.length > 0) return `${side(teamB)} paired together — opponents open`
    return `${side([A1, A2])} vs ${side([B1, B2])}`
  }

  const hint = describe()
  const isPinned = match.mode === 'pinned'

  return (
    <div className={`bg-slate-900 border rounded-2xl p-3 flex flex-col gap-2 ${isPinned ? 'border-indigo-700' : 'border-slate-800'}`}>
      <div className="flex items-center justify-between">
        <div className="flex items-center gap-2">
          {isPinned && <span className="text-xs">📌</span>}
          <span className="text-xs text-slate-400 font-medium">Match #{index + 1}</span>
        </div>
        <div className="flex gap-2">
          <button
            onClick={() => duplicateFixMatch(match.id)}
            className="text-xs text-slate-400 hover:text-slate-200 px-2.5 py-1.5 rounded hover:bg-slate-800 transition-colors"
          >
            Copy
          </button>
          <button
            onClick={() => removeFixMatch(match.id)}
            className="text-xs text-slate-400 hover:text-red-400 px-2.5 py-1.5 rounded hover:bg-slate-800 transition-colors"
            aria-label="Remove match"
          >
            ✕
          </button>
        </div>
      </div>

      {/* Mode toggle */}
      <div className="flex gap-1">
        <button
          onClick={() => updateFixMatch(match.id, { mode: 'flexible' } as Partial<MatchConstraint>)}
          className={`text-xs px-3 py-1 rounded-lg border transition-colors ${
            !isPinned
              ? 'bg-slate-700 border-slate-600 text-white'
              : 'bg-slate-800/60 border-slate-700 text-slate-400 hover:text-white'
          }`}
        >
          Flexible
        </button>
        <button
          onClick={() => updateFixMatch(match.id, { mode: 'pinned' })}
          className={`text-xs px-3 py-1 rounded-lg border transition-colors ${
            isPinned
              ? 'bg-indigo-900/60 border-indigo-700 text-indigo-300'
              : 'bg-slate-800/60 border-slate-700 text-slate-400 hover:text-indigo-300'
          }`}
        >
          📌 Pinned
        </button>
      </div>

      {/* Player selectors */}
      <div className="flex items-center gap-2">
        <div className="flex gap-1.5 flex-1 min-w-0">
          <SlotPicker label="A1" value={A1} onChange={(v) => setSlot(0, v)} players={players} exclude={used.filter((id) => id !== A1)} />
          <SlotPicker label="A2" value={A2} onChange={(v) => setSlot(1, v)} players={players} exclude={used.filter((id) => id !== A2)} />
        </div>
        <span className="text-slate-400 font-bold text-xs shrink-0">vs</span>
        <div className="flex gap-1.5 flex-1 min-w-0">
          <SlotPicker label="B1" value={B1} onChange={(v) => setSlot(2, v)} players={players} exclude={used.filter((id) => id !== B1)} />
          <SlotPicker label="B2" value={B2} onChange={(v) => setSlot(3, v)} players={players} exclude={used.filter((id) => id !== B2)} />
        </div>
      </div>

      {/* Time/Court pickers (pinned only) */}
      {match.mode === 'pinned' && (
        <div className="flex gap-2 items-end">
          <div className="flex flex-col gap-1 flex-1">
            <span className="text-[10px] text-slate-400">⏰ Time</span>
            <select
              value={match.pinnedTime}
              onChange={(e) => updateFixMatch(match.id, { pinnedTime: e.target.value || toTimeString(''), pinnedCourt: e.target.value ? match.pinnedCourt : 0 } as Partial<MatchConstraint>)}
              className="bg-elevated border border-border rounded-lg px-2 py-1.5 text-xs text-white focus:outline-none focus:border-indigo-500 focus-visible:ring-2 focus-visible:ring-indigo-500/50 cursor-pointer"
            >
              <option value="">— Select time —</option>
              {timeSlots.map((t) => (
                <option key={t} value={t}>{t}</option>
              ))}
            </select>
          </div>
          <div className="flex flex-col gap-1 flex-1">
            <span className="text-[10px] text-slate-400">🏸 Court</span>
            <select
              value={match.pinnedCourt}
              onChange={(e) => updateFixMatch(match.id, { pinnedCourt: e.target.value ? Number(e.target.value) : 0 } as Partial<MatchConstraint>)}
              disabled={!match.pinnedTime}
              className="bg-elevated border border-border rounded-lg px-2 py-1.5 text-xs text-white focus:outline-none focus:border-indigo-500 focus-visible:ring-2 focus-visible:ring-indigo-500/50 cursor-pointer disabled:opacity-40 disabled:cursor-not-allowed"
            >
              <option value="">— Select court —</option>
              {availableCourts.map((c) => (
                <option key={c} value={c}>{session.courtNames?.[c] || `Court ${c + 1}`}</option>
              ))}
            </select>
          </div>
        </div>
      )}

      {/* Conflict warnings */}
      {conflicts.length > 0 && (
        <div className="flex flex-col gap-0.5">
          {conflicts.map((msg, i) => (
            <p key={i} className="text-[11px] text-red-400">⚠ {msg}</p>
          ))}
        </div>
      )}

      {/* Description hint */}
      {hint && !isPinned && (
        <p className="text-xs text-indigo-400 bg-indigo-900/20 border border-indigo-800/40 rounded-lg px-3 py-1.5">
          {hint}
        </p>
      )}
      {hint && isPinned && match.pinnedTime && match.pinnedCourt !== undefined && (
        <p className="text-xs text-indigo-400 bg-indigo-900/20 border border-indigo-800/40 rounded-lg px-3 py-1.5">
          📌 {match.pinnedTime} · {session.courtNames?.[match.pinnedCourt] || `Court ${match.pinnedCourt + 1}`} · {hint}
        </p>
      )}
    </div>
  )
}
