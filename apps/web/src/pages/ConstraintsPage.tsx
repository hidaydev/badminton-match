import { toPlayerId } from '../types'
import { useStore } from '../store'
import { useNavigate } from 'react-router-dom'
import { FixMatchCard, ValidationPanel, useValidation } from '../components/constraints'

// ── Page ──────────────────────────────────────────────────────────────────────
export default function ConstraintsPage() {
  const players = useStore((s) => s.players)
  const fixMatches = useStore((s) => s.fixMatches)
  const addFixMatch = useStore((s) => s.addFixMatch)
  const navigate = useNavigate()
  const { hasErrors, pinnedConflicts } = useValidation(players, fixMatches)

  return (
    <div className="flex flex-col gap-6">
      <div className="flex items-start justify-between gap-2">
        <div>
          <h2 className="text-lg font-bold text-fg mb-0.5">Constraints</h2>
          <p className="text-slate-400 text-sm">Define fixed matches. Pin to time & court or leave flexible for the generator.</p>
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
            <FixMatchCard
              key={m.id}
              match={m}
              index={i}
              players={players}
              conflicts={pinnedConflicts.get(i) ?? []}
            />
          ))}
        </div>
      )}

      {fixMatches.length === 0 && (
        <div className="text-center py-12 text-slate-400">
          <svg width="36" height="36" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5" className="mx-auto mb-3 text-slate-500"><circle cx="12" cy="12" r="9"/><circle cx="12" cy="12" r="5"/><circle cx="12" cy="12" r="1.5"/></svg>
          <p className="text-sm">No fixed matches yet. Add one to force specific pairings.</p>
        </div>
      )}

      <button
        onClick={() => addFixMatch({ slots: [toPlayerId(''), toPlayerId(''), toPlayerId(''), toPlayerId('')], mode: 'flexible' })}
        disabled={players.length < 2}
        className="w-full py-2.5 border-2 border-dashed border-slate-700 hover:border-indigo-500 disabled:opacity-30 disabled:cursor-not-allowed text-slate-400 hover:text-indigo-400 rounded-xl text-sm font-medium transition-colors"
      >
        + Add Fixed Match
      </button>

      {players.length < 2 && (
        <p className="text-xs text-center text-slate-400">Add at least 2 players first.</p>
      )}

      <button
        onClick={() => navigate('/session/generate')}
        disabled={hasErrors}
        className="w-full py-2.5 bg-indigo-400 hover:bg-indigo-300 disabled:opacity-40 disabled:cursor-not-allowed text-slate-950 font-semibold rounded-xl transition-colors"
      >
        {hasErrors ? 'Fix errors above to continue' : 'Next: Generate →'}
      </button>
    </div>
  )
}
