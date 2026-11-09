import { useEffect, useId, useState } from 'react'
import { useStore } from '../store'
import { selectTotalGames } from '../store/selectors'
import { PLAYERS_PER_GAME } from '../types'
import type { SessionScoring } from '../types'
import { timeToMinutes, minutesToTime, todayLocal } from '../utils/time'
import { setActiveTimeZone } from '../../utils/day'
import { courtLabel } from '../utils/courtLabel'
import { useLegacySlug, useNavigate } from '../router'
import { fetchCommunityConfigBundle } from '../../community/api'
import type { ScoringPreset } from '../../community/api'
import { Radio } from '../../components/Radio'
import { t } from '../../i18n'

// ── helpers ───────────────────────────────────────────────────────────────────

function timeOptions(from: number, to: number): string[] {
  const opts: string[] = []
  for (let m = from; m <= to; m += 60) opts.push(minutesToTime(m))
  return opts
}

function hourLabel(t: string): string {
  return String(parseInt(t.split(':')[0], 10))
}

const DURATION_OPTIONS = [15, 20, 30]

// ── sub-components ────────────────────────────────────────────────────────────

function PlaysPerPlayer({ totalGames, playerCount }: { totalGames: number; playerCount: number }) {
  if (playerCount < 2 || totalGames === 0) return null
  const total = totalGames * PLAYERS_PER_GAME
  const min = Math.floor(total / playerCount)
  const max = Math.ceil(total / playerCount)
  const label = min === max ? `${min}x` : `${min}–${max}x`
  return (
    <span className="text-slate-400">
      {' '}→ each player plays <strong className="text-white">{label}</strong>
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
  onChange: (v: number) => void
  disabled: boolean
}) {
  return (
    <div className="flex flex-col gap-1" role="group" aria-label={label}>
      <span className="text-xs text-slate-400">{label}</span>
      <div className="flex items-center gap-2">
        <button
          aria-label={`Decrease ${label.toLowerCase()}`}
          disabled={disabled || value <= min}
          onClick={() => onChange(Math.max(min, value - 1))}
          className="inline-flex h-11 w-11 shrink-0 items-center justify-center rounded-lg bg-slate-700 hover:bg-slate-600 disabled:opacity-30 disabled:cursor-not-allowed text-white font-bold transition-colors"
        >
          −
        </button>
        <span className="w-10 text-center text-white font-semibold text-lg">{value}</span>
        <button
          aria-label={`Increase ${label.toLowerCase()}`}
          disabled={disabled || value >= max}
          onClick={() => onChange(Math.min(max, value + 1))}
          className="inline-flex h-11 w-11 shrink-0 items-center justify-center rounded-lg bg-slate-700 hover:bg-slate-600 disabled:opacity-30 disabled:cursor-not-allowed text-white font-bold transition-colors"
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
  onChange: (v: string) => void
  disabled: boolean
  label: string
}) {
  return (
    <select
      value={value}
      disabled={disabled}
      onChange={(e) => onChange(e.target.value)}
      aria-label={label}
      className="bg-elevated border border-border rounded-lg px-2 py-1.5 text-sm text-white focus:outline-none focus:border-accent focus-visible:ring-2 focus-visible:ring-accent disabled:opacity-40 disabled:cursor-not-allowed cursor-pointer h-11"
    >
      {options.map((o) => (
        <option key={o} value={o}>{hourLabel(o)}</option>
      ))}
    </select>
  )
}

function CourtTimeline({
  courtTimes,
  slotMinutes,
  courtNames = [],
}: {
  courtTimes: { start: string; end: string }[]
  slotMinutes: number
  courtNames?: string[]
}) {
  if (courtTimes.length === 0) return null

  const allMins = courtTimes.flatMap((ct) => [timeToMinutes(ct.start), timeToMinutes(ct.end)])
  const earliest = Math.min(...allMins)
  const latest = Math.max(...allMins)
  const span = latest - earliest
  if (span <= 0) return null

  const COURT_COLORS = [
    'bg-indigo-500',
    'bg-sky-500',
    'bg-emerald-500',
    'bg-amber-500',
    'bg-red-500',
    'bg-sky-500',
  ]

  const tickCount = Math.round(span / 30) + 1
  const ticks = Array.from({ length: tickCount }, (_, i) => earliest + i * 30)

  return (
    <div className="flex flex-col gap-2">
      <span className="text-xs text-slate-400">Timeline</span>
      <div className="relative">
        {/* tick labels */}
        <div className="flex relative h-5 mb-1">
          {ticks.map((t) => {
            const pct = ((t - earliest) / span) * 100
            return (
              <span
                key={t}
                className="absolute text-[10px] text-slate-400 -translate-x-1/2"
                style={{ left: `${pct}%` }}
              >
                {minutesToTime(t)}
              </span>
            )
          })}
        </div>
        {/* court bars */}
        <div className="flex flex-col gap-1">
          {courtTimes.map((ct, i) => {
            const startPct = ((timeToMinutes(ct.start) - earliest) / span) * 100
            const endPct = ((timeToMinutes(ct.end) - earliest) / span) * 100
            const slots = Math.max(0, Math.floor((timeToMinutes(ct.end) - timeToMinutes(ct.start)) / slotMinutes))
            return (
              <div key={i} className="flex items-center gap-2">
                <span className="text-[10px] text-slate-400 w-12 shrink-0">{courtLabel(courtNames, i)}</span>
                <div className="flex-1 relative h-5 bg-slate-800 rounded">
                  <div
                    className={`absolute h-full rounded ${COURT_COLORS[i % COURT_COLORS.length]} opacity-80 flex items-center justify-center`}
                    style={{ left: `${startPct}%`, width: `${endPct - startPct}%` }}
                  >
                    <span className="text-[10px] text-white font-semibold">{slots} game{slots !== 1 ? 's' : ''}</span>
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

// ── page ──────────────────────────────────────────────────────────────────────

function toScoring(preset: ScoringPreset): SessionScoring {
  return {
    preset: preset.id,
    label: preset.label,
    gamesToWin: preset.gamesToWin,
    pointsToWin: preset.pointsToWin,
    winBy: preset.winBy,
    maxPoints: preset.maxPoints,
    deuceAt: preset.deuceAt,
    changeEndsAt: preset.changeEndsAt,
  }
}

function formatSummary(preset: ScoringPreset): string {
  const head = preset.gamesToWin === 1
    ? `One game to ${preset.pointsToWin}`
    : `Best of ${2 * preset.gamesToWin - 1} · first to ${preset.pointsToWin}`
  const deuce = preset.deuceAt !== null ? ` · deuce ${preset.deuceAt}` : ''
  const cap = preset.maxPoints !== preset.pointsToWin ? ` · cap ${preset.maxPoints}` : ''
  return head + deuce + cap
}

export default function SetupPage() {
  const session = useStore((s) => s.session)
  const setCourts = useStore((s) => s.setCourts)
  const setSessionStart = useStore((s) => s.setSessionStart)
  const setSlotMinutes = useStore((s) => s.setSlotMinutes)
  const setCourtTime = useStore((s) => s.setCourtTime)
  const setCourtName = useStore((s) => s.setCourtName)
  const setPlayerCount = useStore((s) => s.setPlayerCount)
  const setTitle = useStore((s) => s.setTitle)
  const setDate = useStore((s) => s.setDate)
  const setScoringPreset = useStore((s) => s.setScoringPreset)
  const lockSession = useStore((s) => s.lockSession)
  const resetSession = useStore((s) => s.resetSession)
  const navigate = useNavigate()
  const slug = useLegacySlug()
  const titleId = useId()
  const dateId = useId()
  const durationId = useId()

  const [presets, setPresets] = useState<ScoringPreset[]>([])
  const [defaultPreset, setDefaultPreset] = useState('')
  // The date the draft opened with. The store builds it before the community's
  // zone is known, so a zone that is not the default is applied only while the
  // field still holds that value: a date the host typed stays theirs.
  const [openedOn] = useState(() => useStore.getState().session.date)

  // The list, the community default and the community timezone arrive together
  // from the config read.
  useEffect(() => {
    if (slug === '') return
    let active = true
    fetchCommunityConfigBundle(slug)
      .then(({ presets: list, config }) => {
        if (!active) return
        setPresets(list)
        const fallback = config['session.default_scoring_preset']?.value
        setDefaultPreset(typeof fallback === 'string' ? fallback : '')
        const zone = config['community.default_timezone']?.value
        setActiveTimeZone(typeof zone === 'string' ? zone : null)
        if (useStore.getState().session.date === openedOn) setDate(todayLocal())
      })
      .catch(() => { if (active) setPresets([]) })
    return () => { active = false }
  }, [slug, openedOn, setDate])

  // A draft with no format opens on the community default; once a format is
  // chosen the effect must not overwrite it.
  useEffect(() => {
    if (session.scoring !== undefined || presets.length === 0) return
    const chosen = presets.find((preset) => preset.id === defaultPreset) ?? presets[0]
    setScoringPreset(toScoring(chosen))
  }, [presets, defaultPreset, session.scoring, setScoringPreset])

  // No auto-reset on mount: coming back here from the Players step used to
  // wipe the roster, schedule and scores. "Reset All" stays explicit below.

  const sessionStartMin = timeToMinutes(session.sessionStart)
  const startOpts = timeOptions(6 * 60, 22 * 60)
  // per-court start: must be >= sessionStart
  const courtStartOpts = timeOptions(sessionStartMin, 22 * 60)

  const minPlayersNeeded = session.courts * 4
  const courtError =
    session.playerCount < minPlayersNeeded
      ? `Need at least ${minPlayersNeeded} players for ${session.courts} courts — add more or reduce courts.`
      : null

  // The API trims and caps the title at 120 characters; keeping the input to
  // the same bound means publishing cannot fail on a title the form accepted.
  const titleLength = session.title.trim().length
  const canLock = !courtError && titleLength > 0 && titleLength <= 120 &&
    session.date !== ''

  function handleLock() {
    lockSession()
    navigate('/session/players')
  }

  return (
    <div className="flex flex-col gap-5">
      <div>
        <h1 className="text-lg font-bold text-fg mb-0.5">Session Setup</h1>
        <p className="text-slate-400 text-sm">Configure courts and time slots. Settings lock once session starts.</p>
      </div>

      <div className="bg-surface border border-border-subtle rounded-lg p-4 flex flex-col gap-5">

        {/* Block 0: Session identity */}
        <div className="flex flex-wrap gap-4">
          <div className="flex flex-col gap-1 flex-1 min-w-45">
            <label htmlFor={titleId} className="text-xs text-slate-400">Session title</label>
            <input
              id={titleId}
              type="text"
              value={session.title}
              onChange={(e) => setTitle(e.target.value)}
              maxLength={120}
              placeholder={t('legacy.placeholder.sessionTitle')}
              disabled={session.locked}
              className="bg-elevated border border-border rounded-lg px-3 py-1.5 text-sm text-white placeholder-slate-500 focus:outline-none focus:border-accent focus-visible:ring-2 focus-visible:ring-accent disabled:opacity-40 disabled:cursor-not-allowed h-9"
            />
          </div>
          <div className="flex flex-col gap-1 min-w-35">
            <label htmlFor={dateId} className="text-xs text-slate-400">Date</label>
            <input
              id={dateId}
              type="date"
              value={session.date}
              onChange={(e) => setDate(e.target.value)}
              disabled={session.locked}
              className="bg-elevated border border-border rounded-lg px-2 py-1.5 text-sm text-white focus:outline-none focus:border-accent focus-visible:ring-2 focus-visible:ring-accent disabled:opacity-40 disabled:cursor-not-allowed cursor-pointer h-11"
            />
          </div>
        </div>

        {/* Block 0b: Match format */}
        <fieldset className="flex flex-col gap-2" disabled={session.locked}>
          <legend className="text-xs text-slate-400">Match format</legend>
          <div className="flex flex-wrap gap-2">
            {presets.map((preset) => {
              const selected = session.scoring?.preset === preset.id
              return (
                <label
                  key={preset.id}
                  className={`flex min-h-11 cursor-pointer flex-col gap-0.5 rounded-xl border px-3 py-2 transition-colors ${
                    selected
                      ? 'border-indigo-500 bg-indigo-900/40'
                      : 'border-border bg-elevated hover:border-indigo-400'
                  } ${session.locked ? 'cursor-not-allowed opacity-40' : ''}`}
                >
                  <span className="flex items-center gap-2">
                    <Radio
                      name="scoringPreset"
                      value={preset.id}
                      checked={selected}
                      onChange={() => setScoringPreset(toScoring(preset))}
                      disabled={session.locked}
                      className="h-4 w-4"
                    />
                    <span className="text-sm font-semibold text-white">{preset.label}</span>
                  </span>
                  <span className="pl-6 text-[10px] text-slate-400">{formatSummary(preset)}</span>
                </label>
              )
            })}
          </div>
        </fieldset>

        {/* Block 1: Players + Duration */}
        <div className="flex flex-wrap gap-6 items-end">
          <NumInput
            label="Players"
            value={session.playerCount}
            min={4}
            max={60}
            onChange={setPlayerCount}
            disabled={session.locked}
          />
          <NumInput
            label="Courts"
            value={session.courts}
            min={1}
            max={6}
            onChange={setCourts}
            disabled={session.locked}
          />
          <div className="flex flex-col gap-1">
            <span className="text-xs text-slate-400">Session start</span>
            <TimeSelect
              value={session.sessionStart}
              options={startOpts}
              onChange={setSessionStart}
              disabled={session.locked}
              label="Session start time"
            />
          </div>
          <div className="flex flex-col gap-1">
            <label htmlFor={durationId} className="text-xs text-slate-400">Game duration</label>
            <select
              id={durationId}
              value={session.slotMinutes}
              disabled={session.locked}
              onChange={(e) => setSlotMinutes(Number(e.target.value))}
              className="bg-elevated border border-border rounded-lg px-2 py-1.5 text-sm text-white focus:outline-none focus:border-accent focus-visible:ring-2 focus-visible:ring-accent disabled:opacity-40 disabled:cursor-not-allowed cursor-pointer h-11"
            >
              {DURATION_OPTIONS.map((d) => (
                <option key={d} value={d}>{d} min</option>
              ))}
            </select>
          </div>
        </div>

        {/* Block 2: Per-court times */}
        <div className="flex flex-col gap-2">
          <span className="text-xs text-slate-400">Court hours</span>
          <div className="flex flex-col gap-2">
            {session.courtTimes.map((ct, i) => {
              const slots = Math.max(0, Math.floor((timeToMinutes(ct.end) - timeToMinutes(ct.start)) / session.slotMinutes))
              const endMin = Math.ceil((timeToMinutes(ct.start) + session.slotMinutes) / 60) * 60
              const endOpts = timeOptions(endMin, 23 * 60)
              return (
                <div key={i} className="flex items-center gap-3 bg-slate-800 rounded-xl px-3 py-2 flex-wrap">
                  <input
                    value={session.courtNames?.[i] ?? ''}
                    onChange={(e) => setCourtName(i, e.target.value)}
                    placeholder={courtLabel(session.courtNames, i)}
                    aria-label={`Court ${i + 1} name`}
                    className="w-20 bg-transparent text-sm text-slate-300 placeholder-slate-400 focus:outline-none focus:text-white focus-visible:ring-2 focus-visible:ring-accent focus-visible:rounded-lg"
                  />
                  <TimeSelect
                    value={ct.start}
                    options={courtStartOpts}
                    onChange={(v) => setCourtTime(i, v, ct.end)}
                    disabled={session.locked}
                    label={`Court ${i + 1} start time`}
                  />
                  <span className="text-slate-400 text-xs">→</span>
                  <TimeSelect
                    value={ct.end}
                    options={endOpts}
                    onChange={(v) => setCourtTime(i, ct.start, v)}
                    disabled={session.locked}
                    label={`Court ${i + 1} end time`}
                  />
                  <span className="text-xs text-slate-400 ml-auto">
                    {slots} game{slots !== 1 ? 's' : ''}
                  </span>
                </div>
              )
            })}
          </div>
        </div>

        {/* Block 3: Timeline */}
        <CourtTimeline courtTimes={session.courtTimes} slotMinutes={session.slotMinutes} courtNames={session.courtNames ?? []} />

        {/* Block 4: Summary */}
        <div className="flex items-center justify-between bg-slate-800 rounded-xl px-3 py-2">
          <span className="text-sm text-slate-400">Total Games</span>
          <span className="text-xl font-bold text-indigo-400">{selectTotalGames(session)}</span>
        </div>

        {courtError && !session.locked && (
          <div className="flex items-center gap-2 p-3 bg-red-900/30 border border-red-700 rounded-xl text-red-400 text-sm">
            <span>⚠</span>
            <span>{courtError}</span>
          </div>
        )}

        {!session.locked && (!session.title.trim() || !session.date) && !courtError && (
          <p className="text-xs text-slate-400">Session title and date are required to start.</p>
        )}

        {session.locked ? (
          <div className="flex items-center gap-3 p-3 bg-emerald-900/30 border border-emerald-700 rounded-xl text-emerald-400 text-sm">
            <span>✓</span>
            <span>Session is active — settings locked</span>
            <button
              onClick={resetSession}
              className="ml-auto inline-flex min-h-11 min-w-11 items-center justify-center text-xs text-red-400 hover:text-red-300 transition-colors"
            >
              {t('legacy.resetAll')}
            </button>
          </div>
        ) : (
          <button
            onClick={handleLock}
            disabled={!canLock}
            className="w-full min-h-11 py-2.5 bg-indigo-400 hover:bg-indigo-300 active:bg-indigo-700 disabled:opacity-40 disabled:cursor-not-allowed text-slate-950 font-semibold rounded-xl transition-colors hit44"
          >
            Start Session →
          </button>
        )}
      </div>

      <div className="text-xs text-slate-400 leading-relaxed">
        <p>
          {session.courts} court{session.courts > 1 ? 's' : ''} · {selectTotalGames(session)} total games.
          <PlaysPerPlayer totalGames={selectTotalGames(session)} playerCount={session.playerCount} />
        </p>
      </div>
    </div>
  )
}
