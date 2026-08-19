import { useNavigate } from 'react-router-dom'
import { useListTournaments } from '../queries'

/** Daftar tournament (metadata). */
export default function TournamentListPage() {
  const navigate = useNavigate()
  const { data: tournaments = [], isLoading, isError } = useListTournaments()

  if (isLoading) return <p className="text-fg-dim text-sm">Loading tournaments…</p>
  if (isError) return <p className="text-error text-sm">Failed to load tournaments.</p>

  return (
    <div className="flex flex-col gap-3">
      <div className="flex items-center justify-between gap-2">
        <h2 className="text-lg font-bold text-fg">Tournaments</h2>
        <button
          onClick={() => navigate('/tournaments/new')}
          className="px-3 py-2 rounded-lg bg-accent text-slate-950 text-sm font-bold hover:brightness-110 active:scale-[0.98] transition-all"
        >
          + New
        </button>
      </div>

      <p className="text-xs font-mono text-fg-dim">
        <span className="text-accent">{tournaments.length}</span> tournament{tournaments.length !== 1 ? 's' : ''}
      </p>

      {tournaments.length === 0 && (
        <p className="text-fg-dim text-xs font-mono text-center py-8">
          No tournaments yet.
        </p>
      )}

      {tournaments.length > 0 && (
        <div className="bg-surface border border-border-subtle rounded-lg divide-y divide-border-subtle overflow-hidden">
          {tournaments.map((t) => (
            <a
              key={t.id}
              href={`/tournaments/${t.id}`}
              className="flex items-center gap-3 px-4 py-3 hover:bg-elevated transition-colors"
            >
              <div className="flex flex-col min-w-0 flex-1">
                <p className="text-sm font-semibold text-fg truncate">{t.name || 'Untitled Tournament'}</p>
                <p className="text-xs text-fg-dim mt-0.5 font-mono">{t.date.split('-').reverse().join('-')}</p>
              </div>
              <div className="text-right shrink-0 flex flex-col items-end gap-1">
                <span className={`text-[10px] font-mono uppercase tracking-wider px-1.5 py-0.5 rounded border ${
                  t.format === 'team' ? 'text-accent border-accent/40' : 'text-fg-dim border-border'
                }`}>
                  {t.format === 'team' ? 'team' : 'classic'}
                </span>
              </div>
            </a>
          ))}
        </div>
      )}
    </div>
  )
}
