import { useListTournaments } from '../queries'

/** Daftar tournament (metadata) — pola SessionListPage. Create menyusul. */
export default function TournamentListPage() {
  const { data: tournaments = [], isLoading, isError } = useListTournaments()

  if (isLoading) return <p className="text-fg-dim text-sm">Loading tournaments…</p>
  if (isError) return <p className="text-error text-sm">Failed to load tournaments.</p>

  return (
    <div className="flex flex-col gap-3">
      <div className="flex items-center justify-between">
        <h2 className="text-lg font-bold text-fg">Tournaments</h2>
      </div>

      <p className="text-xs font-mono text-fg-dim">
        <span className="text-accent">{tournaments.length}</span> tournament{tournaments.length !== 1 ? 's' : ''}
      </p>

      {tournaments.length === 0 && (
        <p className="text-fg-dim text-xs font-mono text-center py-8">
          Belum ada tournament.
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
              <div className="text-right shrink-0">
                <p className="text-xs text-fg-dim font-mono">16 pairs</p>
              </div>
            </a>
          ))}
        </div>
      )}
    </div>
  )
}
