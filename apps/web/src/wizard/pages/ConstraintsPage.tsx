import { useNavigate, useParams, Navigate } from 'react-router-dom'
import { t } from '../../i18n'
import { FixMatchCard, ValidationPanel } from '../components/Constraints'
import { useValidation } from '../components/useValidation'
import { useWizard } from '../context'

export default function ConstraintsPage() {
  const { slug = '' } = useParams<{ slug: string }>()
  const navigate = useNavigate()
  const { draft, addFixMatch } = useWizard()
  const players = draft.players
  const fixMatches = draft.fixMatches
  const { hasErrors, pinnedConflicts } = useValidation(players, fixMatches)

  if (!draft.session.locked) {
    return <Navigate to={`/c/${encodeURIComponent(slug)}/session/new`} replace />
  }
  if (players.length !== draft.session.playerCount) {
    return <Navigate to={`/c/${encodeURIComponent(slug)}/session/players`} replace />
  }

  return (
    <div className="flex flex-col gap-6">
      <div className="flex items-start justify-between gap-2">
        <div>
          <h2 className="text-lg font-bold text-fg mb-0.5">{t('wizard.constraints.title')}</h2>
          <p className="text-slate-400 text-sm">{t('wizard.constraints.subtitle')}</p>
        </div>
        {fixMatches.length > 0 && (
          <span
            className={`text-sm font-semibold px-3 py-1 rounded-full border whitespace-nowrap shrink-0 ${
              hasErrors
                ? 'text-red-400 border-red-700 bg-red-900/30'
                : 'text-slate-400 border-slate-700 bg-slate-800'
            }`}
          >
            {fixMatches.length === 1
              ? t('wizard.constraints.countOne')
              : t('wizard.constraints.count', { count: fixMatches.length })}
          </span>
        )}
      </div>

      <ValidationPanel players={players} matches={fixMatches} />

      {fixMatches.length > 0 && (
        <div className="flex flex-col gap-3">
          {fixMatches.map((match, index) => (
            <FixMatchCard
              key={match.id}
              match={match}
              index={index}
              players={players}
              conflicts={pinnedConflicts.get(index) ?? []}
            />
          ))}
        </div>
      )}

      {fixMatches.length === 0 && (
        <div className="text-center py-12 text-slate-400">
          <svg width="36" height="36" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5" className="mx-auto mb-3 text-slate-500">
            <circle cx="12" cy="12" r="9" />
            <circle cx="12" cy="12" r="5" />
            <circle cx="12" cy="12" r="1.5" />
          </svg>
          <p className="text-sm">{t('wizard.constraints.empty')}</p>
        </div>
      )}

      <button
        type="button"
        onClick={() => addFixMatch({ slots: ['', '', '', ''], mode: 'flexible' })}
        disabled={players.length < 2}
        className="w-full py-2.5 border-2 border-dashed border-slate-700 hover:border-accent disabled:opacity-30 disabled:cursor-not-allowed text-slate-400 hover:text-accent rounded-xl text-sm font-medium transition-colors"
      >
        {t('wizard.constraints.add')}
      </button>

      {players.length < 2 && <p className="text-xs text-center text-slate-400">{t('wizard.constraints.minPlayers')}</p>}

      <button
        type="button"
        onClick={() => navigate(`/c/${encodeURIComponent(slug)}/session/generate`)}
        disabled={hasErrors}
        className="w-full py-2.5 bg-accent hover:brightness-110 disabled:opacity-40 disabled:cursor-not-allowed text-slate-950 font-semibold rounded-xl transition-colors"
      >
        {hasErrors ? t('wizard.constraints.fixErrors') : t('wizard.constraints.next')}
      </button>
    </div>
  )
}
