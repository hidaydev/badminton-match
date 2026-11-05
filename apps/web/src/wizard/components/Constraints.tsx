import { t } from '../../i18n'
import { TIER_COLORS, TIER_LABELS } from '../tiers'
import { useWizard } from '../context'
import { computeTimeSlots, courtsAtTime, courtLabel } from '../time'
import type { MatchConstraint, Player } from '../types'
import { PLAYERS_PER_GAME } from '../types'
import { useValidation } from './useValidation'

export function SlotPicker({
  value,
  onChange,
  players,
  exclude,
  label,
}: {
  value: string
  onChange: (value: string) => void
  players: Player[]
  exclude: string[]
  label: string
}) {
  const available = players.filter((player) => !exclude.includes(player.id) || player.id === value)
  const selected = players.find((player) => player.id === value)

  return (
    <div className="flex flex-col gap-1 flex-1 min-w-0">
      <span className="text-[10px] text-slate-400 text-center">{label}</span>
      <select
        value={value}
        onChange={(event) => onChange(event.target.value)}
        aria-label={label}
        className="bg-elevated border border-border rounded-lg px-1.5 py-1.5 text-xs text-white focus:outline-none focus:border-accent focus-visible:ring-2 focus-visible:ring-accent cursor-pointer w-full"
      >
        <option value="">{t('wizard.constraints.any')}</option>
        {available.map((player) => (
          <option key={player.id} value={player.id}>
            {player.name}
          </option>
        ))}
      </select>
      <span className={`text-[10px] text-center h-3 leading-3 ${selected ? (selected.gender === 'M' ? 'text-blue-400' : 'text-pink-400') : 'text-transparent'}`}>
        {selected ? (
          <>
            {selected.gender} ·{' '}
            <span className={TIER_COLORS[selected.tier] ?? 'text-slate-400'}>
              {t('wizard.constraints.tier', { label: TIER_LABELS[selected.tier] ?? selected.tier })}
            </span>
          </>
        ) : (
          '—'
        )}
      </span>
    </div>
  )
}

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
  const { draft, updateFixMatch, duplicateFixMatch, removeFixMatch } = useWizard()
  const session = draft.session
  const timeSlots = computeTimeSlots(session)
  const availableCourts = match.mode === 'pinned' && match.pinnedTime ? courtsAtTime(session, match.pinnedTime) : []

  const [A1, A2, B1, B2] = match.slots
  const used = [A1, A2, B1, B2].filter(Boolean)

  function setSlot(index: 0 | 1 | 2 | 3, value: string) {
    const next = [...match.slots] as MatchConstraint['slots']
    next[index] = value
    updateFixMatch(match.id, { slots: next })
  }

  function describe() {
    const name = (id: string) => players.find((player) => player.id === id)?.name ?? '?'
    const teamA = [A1, A2].filter(Boolean)
    const teamB = [B1, B2].filter(Boolean)
    if (teamA.length === 0 && teamB.length === 0) return null
    const side = (ids: string[]) => ids.map(name).join(' + ')
    if (teamA.length > 0 && teamB.length === 0) {
      return t('wizard.constraints.paired', { names: side(teamA) })
    }
    if (teamA.length === 0 && teamB.length > 0) {
      return t('wizard.constraints.paired', { names: side(teamB) })
    }
    return `${side([A1, A2])} ${t('wizard.constraints.vs')} ${side([B1, B2])}`
  }

  const hint = describe()
  const isPinned = match.mode === 'pinned'

  return (
    <div className={`bg-slate-900 border rounded-lg p-3 flex flex-col gap-2 ${isPinned ? 'border-accent/70' : 'border-slate-800'}`}>
      <div className="flex items-center justify-between">
        <div className="flex items-center gap-2">
          {isPinned && <span className="text-xs">📌</span>}
          <span className="text-xs text-slate-400 font-medium">{t('wizard.constraints.match', { n: index + 1 })}</span>
        </div>
        <div className="flex gap-2">
          <button
            type="button"
            onClick={() => duplicateFixMatch(match.id)}
            className="text-xs text-slate-400 hover:text-slate-200 px-2.5 py-1.5 rounded hover:bg-slate-800 transition-colors"
          >
            {t('wizard.constraints.copy')}
          </button>
          <button
            type="button"
            onClick={() => removeFixMatch(match.id)}
            className="text-xs text-slate-400 hover:text-red-400 px-2.5 py-1.5 rounded hover:bg-slate-800 transition-colors"
            aria-label={t('wizard.constraints.remove')}
          >
            ✕
          </button>
        </div>
      </div>

      <div className="flex gap-1">
        <button
          type="button"
          onClick={() => updateFixMatch(match.id, { mode: 'flexible' })}
          className={`text-xs px-3 py-1 rounded-lg border transition-colors ${
            !isPinned
              ? 'bg-slate-700 border-slate-600 text-white'
              : 'bg-slate-800/60 border-slate-700 text-slate-400 hover:text-white'
          }`}
        >
          {t('wizard.constraints.flexible')}
        </button>
        <button
          type="button"
          onClick={() => updateFixMatch(match.id, { mode: 'pinned' })}
          className={`text-xs px-3 py-1 rounded-lg border transition-colors ${
            isPinned
              ? 'bg-indigo-900/60 border-indigo-700 text-indigo-300'
              : 'bg-slate-800/60 border-slate-700 text-slate-400 hover:text-indigo-300'
          }`}
        >
          {t('wizard.constraints.pinned')}
        </button>
      </div>

      <div className="flex items-center gap-2">
        <div className="flex gap-1.5 flex-1 min-w-0">
          <SlotPicker label="A1" value={A1} onChange={(value) => setSlot(0, value)} players={players} exclude={used.filter((id) => id !== A1)} />
          <SlotPicker label="A2" value={A2} onChange={(value) => setSlot(1, value)} players={players} exclude={used.filter((id) => id !== A2)} />
        </div>
        <span className="text-slate-400 font-bold text-xs shrink-0">{t('wizard.constraints.vs')}</span>
        <div className="flex gap-1.5 flex-1 min-w-0">
          <SlotPicker label="B1" value={B1} onChange={(value) => setSlot(2, value)} players={players} exclude={used.filter((id) => id !== B1)} />
          <SlotPicker label="B2" value={B2} onChange={(value) => setSlot(3, value)} players={players} exclude={used.filter((id) => id !== B2)} />
        </div>
      </div>

      {match.mode === 'pinned' && (
        <div className="flex gap-2 items-end">
          <div className="flex flex-col gap-1 flex-1">
            <span className="text-[10px] text-slate-400">{t('wizard.constraints.time')}</span>
            <select
              value={match.pinnedTime}
              onChange={(event) =>
                updateFixMatch(match.id, {
                  pinnedTime: event.target.value,
                  pinnedCourt: event.target.value ? match.pinnedCourt : 0,
                })
              }
              aria-label={t('wizard.constraints.time')}
              className="bg-elevated border border-border rounded-lg px-2 py-1.5 text-xs text-white focus:outline-none focus:border-accent focus-visible:ring-2 focus-visible:ring-accent cursor-pointer"
            >
              <option value="">{t('wizard.constraints.selectTime')}</option>
              {timeSlots.map((time) => (
                <option key={time} value={time}>
                  {time}
                </option>
              ))}
            </select>
          </div>
          <div className="flex flex-col gap-1 flex-1">
            <span className="text-[10px] text-slate-400">{t('wizard.constraints.court')}</span>
            <select
              value={match.pinnedCourt}
              onChange={(event) => updateFixMatch(match.id, { pinnedCourt: Number(event.target.value) })}
              disabled={!match.pinnedTime}
              aria-label={t('wizard.constraints.court')}
              className="bg-elevated border border-border rounded-lg px-2 py-1.5 text-xs text-white focus:outline-none focus:border-accent focus-visible:ring-2 focus-visible:ring-accent cursor-pointer disabled:opacity-40 disabled:cursor-not-allowed"
            >
              <option value="">{t('wizard.constraints.selectCourt')}</option>
              {availableCourts.map((court) => (
                <option key={court} value={court}>
                  {courtLabel(session.courtNames, court)}
                </option>
              ))}
            </select>
          </div>
        </div>
      )}

      {conflicts.length > 0 && (
        <div className="flex flex-col gap-0.5">
          {conflicts.map((message) => (
            <p key={message} className="text-[11px] text-red-400">
              ⚠ {message}
            </p>
          ))}
        </div>
      )}

      {hint && !isPinned && (
        <p className="text-xs text-indigo-400 bg-indigo-900/20 border border-indigo-800/40 rounded-lg px-3 py-1.5">{hint}</p>
      )}
      {hint && isPinned && match.pinnedTime !== '' && (
        <p className="text-xs text-indigo-400 bg-indigo-900/20 border border-indigo-800/40 rounded-lg px-3 py-1.5">
          {t('wizard.constraints.pinnedSummary', {
            time: match.pinnedTime,
            court: courtLabel(session.courtNames, match.pinnedCourt),
            hint,
          })}
        </p>
      )}
    </div>
  )
}

export function ValidationPanel({ players, matches }: { players: Player[]; matches: MatchConstraint[] }) {
  const { draft, totalGames } = useWizard()
  const { tooManyTotal, effectiveSlotsNeeded, overloadedPlayers, pinnedConflicts, singlePlayerPairs } = useValidation(players, matches)
  const expectedPlays = players.length > 0 ? Math.round((totalGames * PLAYERS_PER_GAME) / players.length) : 0
  const session = draft.session

  const counts: Record<string, number> = {}
  for (const match of matches) {
    for (const id of match.slots) {
      if (id) counts[id] = (counts[id] ?? 0) + 1
    }
  }

  if (matches.length === 0 || players.length === 0) return null

  return (
    <div className="flex flex-col gap-2">
      {tooManyTotal && (
        <div className="flex items-start gap-2 p-3 bg-red-900/30 border border-red-700 rounded-xl text-red-400 text-sm">
          <span>⚠</span>
          <span>
            {t('wizard.constraints.validation.tooMany', {
              needed: effectiveSlotsNeeded,
              available: totalGames,
              excess: effectiveSlotsNeeded - totalGames,
            })}
          </span>
        </div>
      )}

      {overloadedPlayers.length > 0 && (
        <div className="flex flex-col gap-1 p-3 bg-red-900/30 border border-red-700 rounded-xl">
          <span className="text-red-400 text-sm font-medium">{t('wizard.constraints.validation.overloaded')}</span>
          {overloadedPlayers.map(({ player, count, max }) => (
            <span key={player.id} className="text-xs text-red-300 pl-4">
              {t('wizard.constraints.validation.overloadedLine', { name: player.name, count, max })}
            </span>
          ))}
        </div>
      )}

      {pinnedConflicts.size > 0 && (
        <div className="flex flex-col gap-1 p-3 bg-red-900/30 border border-red-700 rounded-xl">
          <span className="text-red-400 text-sm font-medium">{t('wizard.constraints.validation.pinned')}</span>
          {[...pinnedConflicts.entries()].map(([index, messages]) => (
            <div key={index} className="flex flex-col gap-0.5 pl-4">
              <span className="text-xs text-red-300 font-medium">{t('wizard.constraints.validation.match', { n: index + 1 })}</span>
              {messages.map((message) => (
                <span key={message} className="text-xs text-red-300/80 pl-2">
                  · {message}
                </span>
              ))}
            </div>
          ))}
        </div>
      )}

      {singlePlayerPairs.length > 0 && (
        <div className="p-3 bg-amber-900/30 border border-amber-700 rounded-xl text-amber-400 text-sm">
          <p className="font-medium">{t('wizard.constraints.validation.single', { count: singlePlayerPairs.length })}</p>
          <ul className="mt-1 text-xs">
            {singlePlayerPairs.map(({ match, side }) => (
              <li key={`${match.id}-${side}`}>
                {t('wizard.constraints.validation.singleLine', { n: matches.indexOf(match) + 1, side })}
              </li>
            ))}
          </ul>
        </div>
      )}

      <div className="bg-surface border border-border-subtle rounded-lg p-3 flex flex-col gap-2">
        <div className="flex flex-col gap-0.5">
          <span className="text-sm font-semibold text-white">{t('wizard.constraints.validation.assignments')}</span>
          <span className="text-xs text-slate-400">{t('wizard.constraints.validation.max', { count: expectedPlays })}</span>
        </div>
        <div className="flex flex-col gap-1.5">
          {players.map((player) => {
            const count = counts[player.id] ?? 0
            const over = count > expectedPlays
            const percent = Math.min((count / Math.max(expectedPlays, 1)) * 100, 100)
            return (
              <div key={player.id} className="flex items-center gap-2">
                <span className={`w-24 text-xs truncate ${over ? 'text-red-400' : count > 0 ? 'text-slate-300' : 'text-slate-400'}`}>
                  {player.name}
                </span>
                <div className="flex-1 h-1.5 bg-slate-800 rounded-full overflow-hidden">
                  <div
                    className={`h-full rounded-full transition-all ${over ? 'bg-red-500' : count > 0 ? 'bg-accent' : 'bg-slate-700'}`}
                    style={{ width: `${percent}%` }}
                  />
                </div>
                <span className={`text-xs w-14 text-right ${over ? 'text-red-400 font-semibold' : 'text-slate-400'}`}>
                  {count}/{expectedPlays}
                </span>
              </div>
            )
          })}
        </div>
      </div>

      {session.courts > 0 && totalGames === 0 && (
        <p className="text-xs text-slate-400">{t('wizard.setup.courtError', { needed: session.courts * 4, courts: session.courts })}</p>
      )}
    </div>
  )
}
