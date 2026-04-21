import { useStore, PLAYERS_PER_GAME, type Player, type FixMatch } from '../store'
import { useNavigate } from 'react-router-dom'

// ── Player selector ───────────────────────────────────────────────────────────
function SlotPicker({
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
      <span className="text-[10px] text-slate-500 text-center">{label}</span>
      <select
        value={value}
        onChange={(e) => onChange(e.target.value)}
        className="bg-slate-800 border border-slate-700 rounded-lg px-1.5 py-1.5 text-xs text-white focus:outline-none focus:border-indigo-500 cursor-pointer w-full"
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
            {selected.gender} · <span className={selected.tier === 1 ? 'text-red-400' : selected.tier === 2 ? 'text-orange-400' : 'text-yellow-400'}>
              Tier {selected.tier === 1 ? 'A' : selected.tier === 2 ? 'B' : 'C'}
            </span>
          </>
        ) : '—'}
      </span>
    </div>
  )
}

// ── Fix Match card ────────────────────────────────────────────────────────────
function FixMatchCard({
  match,
  index,
  players,
}: {
  match: FixMatch
  index: number
  players: Player[]
}) {
  const { updateFixMatch, duplicateFixMatch, removeFixMatch } = useStore()
  const [A1, A2, B1, B2] = match.slots
  const used = [A1, A2, B1, B2].filter(Boolean)

  function set(i: 0 | 1 | 2 | 3, val: string) {
    const next = [...match.slots] as FixMatch['slots']
    next[i] = val
    updateFixMatch(match.id, next)
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

  return (
    <div className="bg-slate-900 border border-slate-800 rounded-2xl p-3 flex flex-col gap-2">
      <div className="flex items-center justify-between">
        <span className="text-xs text-slate-500 font-medium">Match #{index + 1}</span>
        <div className="flex gap-2">
          <button
            onClick={() => duplicateFixMatch(match.id)}
            className="text-xs text-slate-500 hover:text-slate-300 px-2 py-0.5 rounded hover:bg-slate-800 transition-colors"
          >
            Copy
          </button>
          <button
            onClick={() => removeFixMatch(match.id)}
            className="text-xs text-slate-500 hover:text-red-400 px-2 py-0.5 rounded hover:bg-slate-800 transition-colors"
          >
            ✕
          </button>
        </div>
      </div>

      <div className="flex items-center gap-2">
        <div className="flex gap-1.5 flex-1 min-w-0">
          <SlotPicker label="A1" value={A1} onChange={(v) => set(0, v)} players={players} exclude={used.filter((id) => id !== A1)} />
          <SlotPicker label="A2" value={A2} onChange={(v) => set(1, v)} players={players} exclude={used.filter((id) => id !== A2)} />
        </div>
        <span className="text-slate-500 font-bold text-xs shrink-0">vs</span>
        <div className="flex gap-1.5 flex-1 min-w-0">
          <SlotPicker label="B1" value={B1} onChange={(v) => set(2, v)} players={players} exclude={used.filter((id) => id !== B1)} />
          <SlotPicker label="B2" value={B2} onChange={(v) => set(3, v)} players={players} exclude={used.filter((id) => id !== B2)} />
        </div>
      </div>

      {hint && (
        <p className="text-xs text-indigo-400 bg-indigo-900/20 border border-indigo-800/40 rounded-lg px-3 py-1.5">
          {hint}
        </p>
      )}
    </div>
  )
}

// ── Validation ───────────────────────────────────────────────────────────────
interface ValidationResult {
  hasErrors: boolean
  tooManyTotal: boolean
  effectiveSlotsNeeded: number
  overloadedPlayers: { player: Player; count: number; max: number }[]
}

function useValidation(players: Player[], matches: FixMatch[]): ValidationResult {
  const session = useStore((s) => s.session)
  const expectedPlays = players.length > 0
    ? Math.round((session.totalGames * PLAYERS_PER_GAME) / players.length)
    : 0

  const counts: Record<string, number> = {}
  for (const m of matches) {
    for (const id of m.slots) {
      if (id) counts[id] = (counts[id] ?? 0) + 1
    }
  }

  // Pairable matches (A-side only) can be merged in pairs → each pair uses 1 slot
  const pairableCount = matches.filter(m => !!(m.slots[0] && m.slots[1] && !m.slots[2] && !m.slots[3])).length
  const nonPairableCount = matches.length - pairableCount
  const effectiveSlotsNeeded = Math.ceil(pairableCount / 2) + nonPairableCount
  const tooManyTotal = effectiveSlotsNeeded > session.totalGames
  const overloadedPlayers = players
    .map((p) => ({ player: p, count: counts[p.id] ?? 0, max: expectedPlays }))
    .filter(({ count, max }) => count > max)

  return {
    hasErrors: tooManyTotal || overloadedPlayers.length > 0,
    tooManyTotal,
    effectiveSlotsNeeded,
    overloadedPlayers,
  }
}

function ValidationPanel({ players, matches }: { players: Player[]; matches: FixMatch[] }) {
  const session = useStore((s) => s.session)
  const { tooManyTotal, effectiveSlotsNeeded, overloadedPlayers } = useValidation(players, matches)
  const expectedPlays = players.length > 0
    ? Math.round((session.totalGames * PLAYERS_PER_GAME) / players.length)
    : 0

  const counts: Record<string, number> = {}
  for (const m of matches) {
    for (const id of m.slots) {
      if (id) counts[id] = (counts[id] ?? 0) + 1
    }
  }

  if (matches.length === 0 || players.length === 0) return null

  return (
    <div className="flex flex-col gap-2">
      {/* Total fix matches check */}
      {tooManyTotal && (
        <div className="flex items-start gap-2 p-3 bg-red-900/30 border border-red-700 rounded-xl text-red-400 text-sm">
          <span>⚠</span>
          <span>
            {effectiveSlotsNeeded} game slots needed for fix matches but only {session.totalGames} available — {effectiveSlotsNeeded - session.totalGames} can't be placed.
          </span>
        </div>
      )}

      {/* Per-player overload */}
      {overloadedPlayers.length > 0 && (
        <div className="flex flex-col gap-1 p-3 bg-red-900/30 border border-red-700 rounded-xl">
          <span className="text-red-400 text-sm font-medium">⚠ Players scheduled in too many fix matches:</span>
          {overloadedPlayers.map(({ player, count, max }) => (
            <span key={player.id} className="text-xs text-red-300 pl-4">
              {player.name} — {count} fix matches but max {max} slots available
            </span>
          ))}
        </div>
      )}

      {/* Per-player counts */}
      <div className="bg-slate-900 border border-slate-800 rounded-2xl p-3 flex flex-col gap-2">
        <div className="flex flex-col gap-0.5">
          <span className="text-sm font-semibold text-white">Fix Match Assignments</span>
          <span className="text-xs text-slate-500">max {expectedPlays}x per player (balanced)</span>
        </div>
        <div className="flex flex-col gap-1.5">
          {players.map((p) => {
            const count = counts[p.id] ?? 0
            const over = count > expectedPlays
            const pct = Math.min((count / expectedPlays) * 100, 100)
            return (
              <div key={p.id} className="flex items-center gap-2">
                <span className={`w-24 text-xs truncate ${over ? 'text-red-400' : count > 0 ? 'text-slate-300' : 'text-slate-600'}`}>{p.name}</span>
                <div className="flex-1 h-1.5 bg-slate-800 rounded-full overflow-hidden">
                  <div
                    className={`h-full rounded-full transition-all ${over ? 'bg-red-500' : count > 0 ? 'bg-indigo-500' : 'bg-slate-700'}`}
                    style={{ width: `${pct}%` }}
                  />
                </div>
                <span className={`text-xs w-14 text-right ${over ? 'text-red-400 font-semibold' : count > 0 ? 'text-slate-400' : 'text-slate-600'}`}>
                  {count}/{expectedPlays}{over ? ' ⚠' : ''}
                </span>
              </div>
            )
          })}
        </div>
      </div>
    </div>
  )
}

// ── Page ──────────────────────────────────────────────────────────────────────
export default function ConstraintsPage() {
  const players = useStore((s) => s.players)
  const fixMatches = useStore((s) => s.fixMatches)
  const addFixMatch = useStore((s) => s.addFixMatch)
  const navigate = useNavigate()
  const { hasErrors } = useValidation(players, fixMatches)

  return (
    <div className="flex flex-col gap-6">
      <div className="flex items-start justify-between">
        <div>
          <h2 className="text-2xl font-bold text-white mb-1">Constraints</h2>
          <p className="text-slate-400 text-sm">Define fixed matches. Leave slots as "Any" for open partners or opponents.</p>
        </div>
        {fixMatches.length > 0 && (
          <span className={`text-sm font-semibold px-3 py-1 rounded-full border whitespace-nowrap shrink-0 ${hasErrors ? 'text-red-400 border-red-700 bg-red-900/30' : 'text-slate-400 border-slate-700 bg-slate-800'}`}>
            {fixMatches.length} match{fixMatches.length > 1 ? 'es' : ''}
          </span>
        )}
      </div>

      <ValidationPanel players={players} matches={fixMatches} />

      {fixMatches.length > 0 && (
        <div className="flex flex-col gap-3">
          {fixMatches.map((m, i) => (
            <FixMatchCard key={m.id} match={m} index={i} players={players} />
          ))}
        </div>
      )}

      {fixMatches.length === 0 && (
        <div className="text-center py-12 text-slate-500">
          <div className="text-4xl mb-3">🎯</div>
          <p className="text-sm">No fixed matches yet. Add one to force specific pairings.</p>
        </div>
      )}

      <button
        onClick={() => addFixMatch({ slots: ['', '', '', ''] })}
        disabled={players.length < 2}
        className="w-full py-2.5 border-2 border-dashed border-slate-700 hover:border-indigo-500 disabled:opacity-30 disabled:cursor-not-allowed text-slate-400 hover:text-indigo-400 rounded-xl text-sm font-medium transition-colors"
      >
        + Add Fixed Match
      </button>

      {players.length < 2 && (
        <p className="text-xs text-center text-slate-500">Add at least 2 players first.</p>
      )}

      <button
        onClick={() => navigate('/generate')}
        disabled={hasErrors}
        className="w-full py-2.5 bg-indigo-600 hover:bg-indigo-500 disabled:opacity-40 disabled:cursor-not-allowed text-white font-semibold rounded-xl transition-colors"
      >
        {hasErrors ? 'Fix errors above to continue' : 'Next: Generate →'}
      </button>
    </div>
  )
}
