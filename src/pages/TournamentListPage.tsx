import { useListTournaments } from '../queries'

/** Daftar tournament (metadata) — pola SessionListPage. Create menyusul. */
export default function TournamentListPage() {
  const { data: tournaments = [], isLoading, isError } = useListTournaments()

  if (isLoading) return <p className="text-slate-400 text-sm">Loading tournaments…</p>
  if (isError) return <p className="text-red-400 text-sm">Failed to load tournaments.</p>

  return (
    <div className="flex flex-col gap-3">
      <div className="flex items-center justify-between">
        <h2 className="text-lg font-bold text-white">Tournaments</h2>
      </div>

      <p className="text-xs font-mono text-slate-400">
        <span className="text-amber-400">{tournaments.length}</span> tournament{tournaments.length !== 1 ? 's' : ''}
      </p>

      {tournaments.length === 0 && (
        <p className="text-slate-400 text-xs font-mono text-center py-8">
          Belum ada tournament.
        </p>
      )}

      {tournaments.map((t) => (
        <a
          key={t.id}
          href={`/tournaments/${t.id}`}
          className="block bg-surface border border-border-subtle rounded-xl p-4 hover:border-slate-600 transition-colors"
        >
          <div className="flex items-start justify-between gap-2">
            <div>
              <p className="text-sm font-semibold text-white">{t.name || 'Untitled Tournament'}</p>
              <p className="text-xs text-slate-400 mt-0.5 font-mono">{t.date.split('-').reverse().join('-')}</p>
            </div>
            <div className="text-right shrink-0">
              <p className="text-xs text-slate-400">16 pairs</p>
            </div>
          </div>
        </a>
      ))}
    </div>
  )
}
