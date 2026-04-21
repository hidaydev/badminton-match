import { useStore, PLAYERS_PER_GAME } from '../store'
import { useNavigate } from 'react-router-dom'

function PlaysPerPlayer({ totalGames, playerCount }: { totalGames: number; playerCount: number }) {
  if (playerCount < 2) return null
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

export default function SetupPage() {
  const { session, setCourts, setCourtSlots, setCourtOffset, setPlayerCount, lockSession, resetSession } = useStore()
  const navigate = useNavigate()

  const minPlayersNeeded = session.courts * 4
  const courtError = session.playerCount < minPlayersNeeded
    ? `Need at least ${minPlayersNeeded} players for ${session.courts} courts — add more players or reduce courts.`
    : null

  function handleLock() {
    lockSession()
    navigate('/players')
  }

  return (
    <div className="flex flex-col gap-5">
      <div>
        <h2 className="text-2xl font-bold text-white mb-1">Session Setup</h2>
        <p className="text-slate-400 text-sm">Configure courts and slots. Settings lock once session starts.</p>
      </div>

      <div className="bg-slate-900 border border-slate-800 rounded-2xl p-4 flex flex-col gap-4">

        {/* Top row: Players + Courts */}
        <div className="flex gap-6">
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
        </div>

        {/* Per-court slots */}
        <div className="flex flex-col gap-3">
          <span className="text-xs text-slate-400">Slots per court <span className="text-slate-600">(1 slot = 1 game)</span></span>
          <div className="flex flex-col gap-2">
            {session.slotsPerCourt.map((slots, i) => {
              const offset = session.courtOffsets?.[i] ?? 0
              return (
              <div key={i} className="flex items-center gap-4 bg-slate-800 rounded-xl px-3 py-2 flex-wrap">
                <span className="text-sm text-slate-400 w-16">Court {i + 1}</span>
                <div className="flex items-center gap-2">
                  <button
                    disabled={session.locked || slots <= 1}
                    onClick={() => setCourtSlots(i, slots - 1)}
                    className="w-7 h-7 rounded-lg bg-slate-700 hover:bg-slate-600 disabled:opacity-30 disabled:cursor-not-allowed text-white font-bold text-sm transition-colors"
                  >
                    −
                  </button>
                  <span className="w-8 text-center text-white font-semibold">{slots}</span>
                  <button
                    disabled={session.locked || slots >= 16}
                    onClick={() => setCourtSlots(i, slots + 1)}
                    className="w-7 h-7 rounded-lg bg-slate-700 hover:bg-slate-600 disabled:opacity-30 disabled:cursor-not-allowed text-white font-bold text-sm transition-colors"
                  >
                    +
                  </button>
                </div>
                <span className="text-xs text-slate-500">starts at slot</span>
                <div className="flex items-center gap-2">
                  <button
                    disabled={session.locked || offset <= 0}
                    onClick={() => setCourtOffset(i, offset - 1)}
                    className="w-7 h-7 rounded-lg bg-slate-700 hover:bg-slate-600 disabled:opacity-30 disabled:cursor-not-allowed text-white font-bold text-sm transition-colors"
                  >
                    −
                  </button>
                  <span className="w-6 text-center text-white font-semibold">{offset + 1}</span>
                  <button
                    disabled={session.locked || offset >= 15}
                    onClick={() => setCourtOffset(i, offset + 1)}
                    className="w-7 h-7 rounded-lg bg-slate-700 hover:bg-slate-600 disabled:opacity-30 disabled:cursor-not-allowed text-white font-bold text-sm transition-colors"
                  >
                    +
                  </button>
                </div>
              </div>
              )
            })}
          </div>
        </div>

        {/* Total games stat */}
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
