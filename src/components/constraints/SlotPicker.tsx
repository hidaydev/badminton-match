import type { Player } from '../../types'
import { TIER_LABELS, TIER_COLORS } from '../../config/tiers'

// ── Player selector ───────────────────────────────────────────────────────────
export function SlotPicker({
  value,
  onChange,
  players,
  exclude,
  label,
}: {
  value: string
  onChange: (v: string) => void
  players: Player[]
  exclude: string[]
  label: string
}) {
  const available = players.filter((p) => !exclude.includes(p.id) || p.id === value)
  const selected = players.find((p) => p.id === value)

  return (
    <div className="flex flex-col gap-1 flex-1 min-w-0">
      <span className="text-[10px] text-slate-400 text-center">{label}</span>
      <select
        value={value}
        onChange={(e) => onChange(e.target.value)}
        className="bg-elevated border border-border rounded-lg px-1.5 py-1.5 text-xs text-white focus:outline-none focus:border-indigo-500 focus-visible:ring-2 focus-visible:ring-indigo-500/50 cursor-pointer w-full"
      >
        <option value="">— Any —</option>
        {available.map((p) => (
          <option key={p.id} value={p.id}>
            {p.name}
          </option>
        ))}
      </select>
      <span className={`text-[10px] text-center h-3 leading-3 ${selected ? selected.gender === 'M' ? 'text-blue-400' : 'text-pink-400' : 'text-transparent'}`}>
        {selected ? (
          <>
            {selected.gender} · <span className={TIER_COLORS[selected.tier] ?? 'text-slate-400'}>
              Tier {TIER_LABELS[selected.tier] ?? selected.tier}
            </span>
          </>
        ) : '—'}
      </span>
    </div>
  )
}
