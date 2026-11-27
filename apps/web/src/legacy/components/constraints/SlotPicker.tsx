import type { Player } from '../../types'
import { TIER_LABELS, TIER_COLORS } from '../../config/tiers'
import { Field, Select } from '../../../components/Field'
import { t } from '../../../i18n'

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
      <Field label={label} className="min-w-0 text-center">
        <Select
          value={value}
          onChange={(e) => onChange(e.target.value)}
          className="px-1.5 text-xs"
        >
          <option value="">{t('wizard.constraints.any')}</option>
          {available.map((p) => (
            <option key={p.id} value={p.id}>
              {p.name}
            </option>
          ))}
        </Select>
      </Field>
      <span className={`text-2xs text-center h-3 leading-3 ${selected ? selected.gender === 'M' ? 'text-blue-400' : 'text-red-400' : 'text-transparent'}`}>
        {selected ? (
          <>
            {selected.gender} · <span className={TIER_COLORS[selected.tier] ?? 'text-slate-400'}>
              {t('wizard.constraints.tier', { label: TIER_LABELS[selected.tier] ?? selected.tier })}</span>
          </>
        ) : '—'}
      </span>
    </div>
  )
}
