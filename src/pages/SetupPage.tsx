import { useStore, PLAYERS_PER_GAME, timeToMinutes, minutesToTime } from '../store'
import { useNavigate } from 'react-router-dom'

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
    <div className="flex flex-col gap-1">
      <label className="text-xs text-slate-400">{label}</label>
      <div className="flex items-center gap-2">
        <button
          disabled={disabled || value <= min}
          onClick={() => onChange(Math.max(min, value - 1))}
          className="w-8 h-8 rounded-lg bg-slate-700 hover:bg-slate-600 disabled:opacity-30 disabled:cursor-not-allowed text-white font-bold transition-colors"
        >
          −
        </button>
        <span className="w-10 text-center text-white font-semibold text-lg">{value}</span>
        <button
          disabled={disabled || value >= max}
          onClick={() => onChange(Math.min(max, value + 1))}
          className="w-8 h-8 rounded-lg bg-slate-700 hover:bg-slate-600 disabled:opacity-30 disabled:cursor-not-allowed text-white font-bold transition-colors"
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
}: {
  value: string
  options: string[]
  onChange: (v: string) => void
  disabled: boolean
}) {
  return (
    <select
      value={value}
      disabled={disabled}
      onChange={(e) => onChange(e.target.value)}
      className="bg-slate-800 border border-slate-700 rounded-lg px-2 py-1.5 text-sm text-white focus:outline-none focus:border-indigo-500 disabled:opacity-40 disabled:cursor-not-allowed cursor-pointer"
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
    'bg-rose-500',
    'bg-violet-500',
  ]

  const tickCount = Math.round(span / 30) + 1
  const ticks = Array.from({ length: tickCount }, (_, i) => earliest + i * 30)

  return (
    <div className="flex flex-col gap-2">
      <span className="text-xs text-slate-500">Timeline</span>
      <div className="relative">
        {/* tick labels */}
        <div className="flex relative h-5 mb-1">
          {ticks.map((t) => {
            const pct = ((t - earliest) / span) * 100
            return (
              <span
                key={t}
                className="absolute text-[10px] text-slate-600 -translate-x-1/2"
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
                <span className="text-[10px] text-slate-500 w-12 shrink-0">{courtNames[i] || `Court ${i + 1}`}</span>
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

export default function SetupPage() {
  const {
    session,
    setCourts,
    setSessionStart,
    setSlotMinutes,
    setCourtTime,
    setCourtName,
    setPlayerCount,
    setTierCount,
    lockSession,
    resetSession,
  } = useStore()
  const navigate = useNavigate()

  const sessionStartMin = timeToMinutes(session.sessionStart)
  const startOpts = timeOptions(6 * 60, 22 * 60)
  // per-court start: must be >= sessionStart
  const courtStartOpts = timeOptions(sessionStartMin, 22 * 60)

  const minPlayersNeeded = session.courts * 4
  const courtError =
    session.playerCount < minPlayersNeeded
      ? `Need at least ${minPlayersNeeded} players for ${session.courts} courts — add more or reduce courts.`
      : null

  function handleLock() {
    lockSession()
    navigate('/players')
  }

  return (
    <div className="flex flex-col gap-5">
      <div>
        <h2 className="text-xl sm:text-2xl font-bold text-white mb-0.5">Session Setup</h2>
        <p className="text-slate-400 text-sm">Configure courts and time slots. Settings lock once session starts.</p>
      </div>

      <div className="bg-slate-900 border border-slate-800 rounded-2xl p-4 flex flex-col gap-5">

        {/* Block 1: Players + Duration */}
        <div className="flex flex-wrap gap-6 items-end">
          <NumInput
            label="Players"
            value={session.playerCount}
            min={4}
            max={20}
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
            <label className="text-xs text-slate-400">Session start</label>
            <TimeSelect
              value={session.sessionStart}
              options={startOpts}
              onChange={setSessionStart}
              disabled={session.locked}
            />
          </div>
          <div className="flex flex-col gap-1">
            <label className="text-xs text-slate-400">Game duration</label>
            <select
              value={session.slotMinutes}
              disabled={session.locked}
              onChange={(e) => setSlotMinutes(Number(e.target.value))}
              className="bg-slate-800 border border-slate-700 rounded-lg px-2 py-1.5 text-sm text-white focus:outline-none focus:border-indigo-500 disabled:opacity-40 disabled:cursor-not-allowed cursor-pointer"
            >
              {DURATION_OPTIONS.map((d) => (
                <option key={d} value={d}>{d} min</option>
              ))}
            </select>
          </div>
          <div className="flex flex-col gap-1">
            <label className="text-xs text-slate-400">Skill tiers</label>
            <div className="flex rounded-lg overflow-hidden border border-slate-700">
              {([3, 4] as const).map((n) => (
                <button
                  key={n}
                  disabled={session.locked}
                  onClick={() => setTierCount(n)}
                  className={`px-3 py-1.5 text-xs font-semibold transition-colors disabled:cursor-not-allowed ${
                    session.tierCount === n
                      ? 'bg-indigo-600 text-white'
                      : 'text-slate-400 hover:text-slate-200 hover:bg-slate-700'
                  }`}
                >
                  {n === 3 ? 'A–C' : 'A–D'}
                </button>
              ))}
            </div>
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
                    placeholder={`Court ${i + 1}`}
                    disabled={session.locked}
                    className="w-20 bg-transparent text-sm text-slate-300 placeholder-slate-500 focus:outline-none focus:text-white disabled:cursor-not-allowed"
                  />
                  <TimeSelect
                    value={ct.start}
                    options={courtStartOpts}
                    onChange={(v) => setCourtTime(i, v, ct.end)}
                    disabled={session.locked}
                  />
                  <span className="text-slate-600 text-xs">→</span>
                  <TimeSelect
                    value={ct.end}
                    options={endOpts}
                    onChange={(v) => setCourtTime(i, ct.start, v)}
                    disabled={session.locked}
                  />
                  <span className="text-xs text-slate-500 ml-auto">
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
          <span className="text-2xl font-bold text-indigo-400">{session.totalGames}</span>
        </div>

        {courtError && !session.locked && (
          <div className="flex items-center gap-2 p-3 bg-red-900/30 border border-red-700 rounded-xl text-red-400 text-sm">
            <span>⚠</span>
            <span>{courtError}</span>
          </div>
        )}

        {session.locked ? (
          <div className="flex items-center gap-3 p-3 bg-emerald-900/30 border border-emerald-700 rounded-xl text-emerald-400 text-sm">
            <span>✓</span>
            <span>Session is active — settings locked</span>
            <button
              onClick={resetSession}
              className="ml-auto text-xs text-red-400 hover:text-red-300 transition-colors"
            >
              Reset All
            </button>
          </div>
        ) : (
          <button
            onClick={handleLock}
            disabled={!!courtError}
            className="w-full py-2.5 bg-indigo-600 hover:bg-indigo-500 active:bg-indigo-700 disabled:opacity-40 disabled:cursor-not-allowed text-white font-semibold rounded-xl transition-colors"
          >
            Start Session →
          </button>
        )}
      </div>

      <div className="text-xs text-slate-500 leading-relaxed">
        <p>
          {session.courts} court{session.courts > 1 ? 's' : ''} · {session.totalGames} total games.
          <PlaysPerPlayer totalGames={session.totalGames} playerCount={session.playerCount} />
        </p>
      </div>
    </div>
  )
}
