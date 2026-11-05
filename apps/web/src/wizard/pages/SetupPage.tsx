import { useEffect } from 'react'
import { useNavigate, useParams } from 'react-router-dom'
import { t } from '../../i18n'
import { courtLabel, minutesToTime, timeToMinutes } from '../time'
import { useWizard } from '../context'
import type { CourtTime } from '../types'
import { PLAYERS_PER_GAME } from '../types'

function timeOptions(from: number, to: number): string[] {
  const options: string[] = []
  for (let minute = from; minute <= to; minute += 60) options.push(minutesToTime(minute))
  return options
}

function hourLabel(time: string): string {
  return String(parseInt(time.split(':')[0], 10))
}

const DURATION_OPTIONS = [15, 20, 30]

function PlaysPerPlayer({ totalGames, playerCount }: { totalGames: number; playerCount: number }) {
  if (playerCount < 2 || totalGames === 0) return null
  const total = totalGames * PLAYERS_PER_GAME
  const min = Math.floor(total / playerCount)
  const max = Math.ceil(total / playerCount)
  return (
    <span className="text-slate-400">
      {min === max
        ? t('wizard.setup.eachPlayer', { count: min })
        : t('wizard.setup.eachPlayerRange', { min, max })}
    </span>
  )
}

function NumInput({
  label,
  value,
  min,
  max,
  onChange,
  disabled,
}: {
  label: string
  value: number
  min: number
  max: number
  onChange: (value: number) => void
  disabled: boolean
}) {
  return (
    <div className="flex flex-col gap-1">
      <span className="text-xs text-slate-400">{label}</span>
      <div className="flex items-center gap-2">
        <button
          type="button"
          disabled={disabled || value <= min}
          onClick={() => onChange(Math.max(min, value - 1))}
          className="w-8 h-8 rounded-lg bg-slate-700 hover:bg-slate-600 disabled:opacity-30 disabled:cursor-not-allowed text-white font-bold transition-colors"
          aria-label={t('wizard.setup.decrease')}
        >
          −
        </button>
        <span className="w-10 text-center text-white font-semibold text-lg">{value}</span>
        <button
          type="button"
          disabled={disabled || value >= max}
          onClick={() => onChange(Math.min(max, value + 1))}
          className="w-8 h-8 rounded-lg bg-slate-700 hover:bg-slate-600 disabled:opacity-30 disabled:cursor-not-allowed text-white font-bold transition-colors"
          aria-label={t('wizard.setup.increase')}
        >
          +
        </button>
      </div>
    </div>
  )
}

function TimeSelect({
  value,
  options,
  onChange,
  disabled,
  label,
}: {
  value: string
  options: string[]
  onChange: (value: string) => void
  disabled: boolean
  label: string
}) {
  return (
    <select
      value={value}
      disabled={disabled}
      onChange={(event) => onChange(event.target.value)}
      aria-label={label}
      className="bg-elevated border border-border rounded-lg px-2 py-1.5 text-sm text-white focus:outline-none focus:border-accent focus-visible:ring-2 focus-visible:ring-accent disabled:opacity-40 disabled:cursor-not-allowed cursor-pointer h-9"
    >
      {options.map((option) => (
        <option key={option} value={option}>
          {hourLabel(option)}
        </option>
      ))}
    </select>
  )
}

function CourtTimeline({
  courtTimes,
  slotMinutes,
  courtNames = [],
}: {
  courtTimes: CourtTime[]
  slotMinutes: number
  courtNames?: string[]
}) {
  if (courtTimes.length === 0) return null

  const allMinutes = courtTimes.flatMap((ct) => [timeToMinutes(ct.start), timeToMinutes(ct.end)])
  const earliest = Math.min(...allMinutes)
  const latest = Math.max(...allMinutes)
  const span = latest - earliest
  if (span <= 0) return null

  const COURT_COLORS = ['bg-indigo-500', 'bg-sky-500', 'bg-emerald-500', 'bg-amber-500', 'bg-rose-500', 'bg-violet-500']
  const tickCount = Math.round(span / 30) + 1
  const ticks = Array.from({ length: tickCount }, (_, index) => earliest + index * 30)

  return (
    <div className="flex flex-col gap-2">
      <span className="text-xs text-slate-400">{t('wizard.setup.timeline')}</span>
      <div className="relative">
        <div className="flex relative h-5 mb-1">
          {ticks.map((tick) => {
            const percent = ((tick - earliest) / span) * 100
            return (
              <span key={tick} className="absolute text-[10px] text-slate-400 -translate-x-1/2" style={{ left: `${percent}%` }}>
                {minutesToTime(tick)}
              </span>
            )
          })}
        </div>
        <div className="flex flex-col gap-1">
          {courtTimes.map((ct, index) => {
            const startPercent = ((timeToMinutes(ct.start) - earliest) / span) * 100
            const endPercent = ((timeToMinutes(ct.end) - earliest) / span) * 100
            const slots = Math.max(0, Math.floor((timeToMinutes(ct.end) - timeToMinutes(ct.start)) / slotMinutes))
            return (
              <div key={index} className="flex items-center gap-2">
                <span className="text-[10px] text-slate-400 w-12 shrink-0">{courtLabel(courtNames, index)}</span>
                <div className="flex-1 relative h-5 bg-slate-800 rounded">
                  <div
                    className={`absolute h-full rounded ${COURT_COLORS[index % COURT_COLORS.length]} opacity-80 flex items-center justify-center`}
                    style={{ left: `${startPercent}%`, width: `${endPercent - startPercent}%` }}
                  >
                    <span className="text-[10px] text-white font-semibold">
                      {slots === 1
                        ? t('wizard.setup.gamesCount', { n: slots })
                        : t('wizard.setup.gamesCountPlural', { n: slots })}
                    </span>
                  </div>
                </div>
              </div>
            )
          })}
        </div>
      </div>
    </div>
  )
}

export default function SetupPage() {
  const { slug = '' } = useParams<{ slug: string }>()
  const navigate = useNavigate()
  const {
    draft,
    totalGames,
    setTitle,
    setDate,
    setCourts,
    setSessionStart,
    setSlotMinutes,
    setCourtTime,
    setCourtName,
    setPlayerCount,
    lockSession,
    resetDraft,
  } = useWizard()
  const session = draft.session

  useEffect(() => {
    if (session.locked) resetDraft()
    // A locked draft is a finished session; opening Setup starts a new one.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [])

  const startMinutes = timeToMinutes(session.sessionStart)
  const startOptions = timeOptions(6 * 60, 22 * 60)
  const courtStartOptions = timeOptions(startMinutes, 22 * 60)
  const minPlayersNeeded = session.courts * 4
  const courtError =
    session.playerCount < minPlayersNeeded
      ? t('wizard.setup.courtError', { needed: minPlayersNeeded, courts: session.courts })
      : null
  const canLock = courtError === null && session.title.trim() !== '' && session.date !== ''

  function handleLock() {
    lockSession()
    navigate(`/c/${encodeURIComponent(slug)}/session/players`)
  }

  return (
    <div className="flex flex-col gap-5">
      <div>
        <h2 className="text-lg font-bold text-fg mb-0.5">{t('wizard.setup.title')}</h2>
        <p className="text-slate-400 text-sm">{t('wizard.setup.subtitle')}</p>
      </div>

      <div className="bg-surface border border-border-subtle rounded-lg p-4 flex flex-col gap-5">
        <div className="flex flex-wrap gap-4">
          <div className="flex flex-col gap-1 flex-1 min-w-45">
            <label className="text-xs text-slate-400" htmlFor="session-title">
              {t('wizard.setup.titleLabel')}
            </label>
            <input
              id="session-title"
              type="text"
              value={session.title}
              onChange={(event) => setTitle(event.target.value)}
              placeholder={t('wizard.setup.titlePlaceholder')}
              disabled={session.locked}
              className="bg-elevated border border-border rounded-lg px-3 py-1.5 text-sm text-white placeholder-slate-500 focus:outline-none focus:border-accent focus-visible:ring-2 focus-visible:ring-accent disabled:opacity-40 disabled:cursor-not-allowed h-9"
            />
          </div>
          <div className="flex flex-col gap-1 min-w-35">
            <label className="text-xs text-slate-400" htmlFor="session-date">
              {t('wizard.setup.date')}
            </label>
            <input
              id="session-date"
              type="date"
              value={session.date}
              onChange={(event) => setDate(event.target.value)}
              disabled={session.locked}
              className="bg-elevated border border-border rounded-lg px-2 py-1.5 text-sm text-white focus:outline-none focus:border-accent focus-visible:ring-2 focus-visible:ring-accent disabled:opacity-40 disabled:cursor-not-allowed cursor-pointer h-9"
            />
          </div>
        </div>

        <div className="flex flex-wrap gap-6 items-end">
          <NumInput
            label={t('wizard.setup.players')}
            value={session.playerCount}
            min={4}
            max={60}
            onChange={setPlayerCount}
            disabled={session.locked}
          />
          <NumInput
            label={t('wizard.setup.courts')}
            value={session.courts}
            min={1}
            max={6}
            onChange={setCourts}
            disabled={session.locked}
          />
          <div className="flex flex-col gap-1">
            <span className="text-xs text-slate-400">{t('wizard.setup.sessionStart')}</span>
            <TimeSelect
              value={session.sessionStart}
              options={startOptions}
              onChange={setSessionStart}
              disabled={session.locked}
              label={t('wizard.setup.sessionStart')}
            />
          </div>
          <div className="flex flex-col gap-1">
            <span className="text-xs text-slate-400">{t('wizard.setup.duration')}</span>
            <select
              value={session.slotMinutes}
              disabled={session.locked}
              onChange={(event) => setSlotMinutes(Number(event.target.value))}
              aria-label={t('wizard.setup.duration')}
              className="bg-elevated border border-border rounded-lg px-2 py-1.5 text-sm text-white focus:outline-none focus:border-accent focus-visible:ring-2 focus-visible:ring-accent disabled:opacity-40 disabled:cursor-not-allowed cursor-pointer h-9"
            >
              {DURATION_OPTIONS.map((duration) => (
                <option key={duration} value={duration}>
                  {t('wizard.setup.minutes', { n: duration })}
                </option>
              ))}
            </select>
          </div>
        </div>

        <div className="flex flex-col gap-2">
          <span className="text-xs text-slate-400">{t('wizard.setup.courtHours')}</span>
          <div className="flex flex-col gap-2">
            {session.courtTimes.map((ct, index) => {
              const slots = Math.max(0, Math.floor((timeToMinutes(ct.end) - timeToMinutes(ct.start)) / session.slotMinutes))
              const endMin = Math.ceil((timeToMinutes(ct.start) + session.slotMinutes) / 60) * 60
              const endOptions = timeOptions(endMin, 23 * 60)
              return (
                <div key={index} className="flex items-center gap-3 bg-slate-800 rounded-xl px-3 py-2 flex-wrap">
                  <input
                    value={session.courtNames?.[index] ?? ''}
                    onChange={(event) => setCourtName(index, event.target.value)}
                    placeholder={t('wizard.setup.courtNamePlaceholder')}
                    aria-label={t('wizard.setup.courtNamePlaceholder')}
                    className="w-20 bg-transparent text-sm text-slate-300 placeholder-slate-400 focus:outline-none focus:text-white focus-visible:ring-2 focus-visible:ring-accent focus-visible:rounded-lg"
                  />
                  <TimeSelect
                    value={ct.start}
                    options={courtStartOptions}
                    onChange={(value) => setCourtTime(index, value, ct.end)}
                    disabled={session.locked}
                    label={t('wizard.setup.sessionStart')}
                  />
                  <span className="text-slate-400 text-xs">→</span>
                  <TimeSelect
                    value={ct.end}
                    options={endOptions}
                    onChange={(value) => setCourtTime(index, ct.start, value)}
                    disabled={session.locked}
                    label={t('wizard.setup.duration')}
                  />
                  <span className="text-xs text-slate-400 ml-auto">
                    {slots === 1
                      ? t('wizard.setup.gamesCount', { n: slots })
                      : t('wizard.setup.gamesCountPlural', { n: slots })}
                  </span>
                </div>
              )
            })}
          </div>
        </div>

        <CourtTimeline courtTimes={session.courtTimes} slotMinutes={session.slotMinutes} courtNames={session.courtNames ?? []} />

        <div className="flex items-center justify-between bg-slate-800 rounded-xl px-3 py-2">
          <span className="text-sm text-slate-400">{t('wizard.setup.totalGames')}</span>
          <span className="text-xl font-bold text-accent">{totalGames}</span>
        </div>

        {courtError !== null && !session.locked && (
          <div className="flex items-center gap-2 p-3 bg-red-900/30 border border-red-700 rounded-xl text-red-400 text-sm">
            <span>⚠</span>
            <span>{courtError}</span>
          </div>
        )}

        {!session.locked && (!session.title.trim() || !session.date) && courtError === null && (
          <p className="text-xs text-slate-400">{t('wizard.setup.required')}</p>
        )}

        {session.locked ? (
          <div className="flex items-center gap-3 p-3 bg-emerald-900/30 border border-emerald-700 rounded-xl text-emerald-400 text-sm">
            <span>✓</span>
            <span>{t('wizard.setup.locked')}</span>
            <button
              type="button"
              onClick={resetDraft}
              className="ml-auto text-xs text-red-400 hover:text-red-300 transition-colors"
            >
              {t('wizard.setup.resetAll')}
            </button>
          </div>
        ) : (
          <button
            type="button"
            onClick={handleLock}
            disabled={!canLock}
            className="w-full py-2.5 bg-accent hover:brightness-110 active:scale-[0.99] disabled:opacity-40 disabled:cursor-not-allowed text-slate-950 font-semibold rounded-xl transition-colors"
          >
            {t('wizard.setup.start')}
          </button>
        )}
      </div>

      <div className="text-xs text-slate-400 leading-relaxed">
        <p>
          {session.courts === 1
            ? t('wizard.setup.summaryOne', { games: totalGames })
            : t('wizard.setup.summary', { courts: session.courts, games: totalGames })}
          <PlaysPerPlayer totalGames={totalGames} playerCount={session.playerCount} />
        </p>
      </div>
    </div>
  )
}
