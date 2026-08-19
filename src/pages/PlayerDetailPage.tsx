import { Link, useParams } from 'react-router-dom'
import { useGetPlayerStats } from '../queries'

export default function PlayerDetailPage() {
  const { name } = useParams<{ name: string }>()

  const { data: stats, isLoading, isError } = useGetPlayerStats(name)

  if (isLoading) return <p className="text-slate-400 text-sm">Loading stats…</p>
  if (isError) return <p className="text-red-400 text-sm">Failed to load stats.</p>
  if (!stats) return null

  const winRate = stats.gamesPlayed > 0
    ? Math.round((stats.wins / stats.gamesPlayed) * 100)
    : 0

  return (
    <div className="flex flex-col gap-4">
      <h2 className="text-xl font-bold text-fg">{stats.name}</h2>

      {/* Cross-link ke rating — tampil jika player sudah ter-rating */}
      {stats.playerId && stats.gamesPlayed > 0 && (
        <Link
          to={`/ratings/${stats.playerId}`}
          className="text-xs text-accent hover:brightness-110 transition-colors"
        >
          View rating →
        </Link>
      )}

      <div className="grid grid-cols-2 gap-3">
        {([
          { label: 'Games', value: stats.gamesPlayed },
          { label: 'Win Rate', value: `${winRate}%` },
          { label: 'Wins', value: stats.wins },
          { label: 'Losses', value: stats.losses },
        ] as const).map((stat) => (
          <div key={stat.label} className="bg-surface border border-border-subtle rounded-lg p-4">
            <p className="text-xs text-slate-400">{stat.label}</p>
            <p className="text-2xl font-bold text-fg font-mono mt-1">{stat.value}</p>
          </div>
        ))}
      </div>

      {stats.sessions.length > 0 && (
        <div className="bg-surface border border-border-subtle rounded-lg p-4 flex flex-col gap-2">
          <p className="text-xs font-semibold text-slate-400 uppercase tracking-wider">
            Sessions ({stats.sessions.length})
          </p>
          {stats.sessions.map((s) => (
            <div key={s.id} className="flex justify-between items-center text-sm gap-2">
              <span className={s.absent ? 'text-slate-400 line-through' : 'text-slate-200'}>{s.title || 'Untitled'}</span>
              <div className="flex items-center gap-2 shrink-0">
                {s.absent && <span className="text-[10px] text-slate-400">absent</span>}
                <span className="text-slate-400">{s.date.split('-').reverse().join('-')}</span>
              </div>
            </div>
          ))}
        </div>
      )}

      {stats.topPartners.length > 0 && (
        <div className="bg-surface border border-border-subtle rounded-lg p-4 flex flex-col gap-2">
          <p className="text-xs font-semibold text-slate-400 uppercase tracking-wider">Top Partners</p>
          {stats.topPartners.map((p) => (
            <div key={p.name} className="flex items-center justify-between">
              <span className="text-sm text-slate-200">{p.name}</span>
              <div className="flex items-center gap-1.5 font-mono text-[9px]">
                <span className="text-emerald-400 font-semibold">{p.wins}W</span>
                <span className="text-red-400 font-semibold">{p.losses}L</span>
                <span className="text-slate-400">{p.count}×</span>
              </div>
            </div>
          ))}
        </div>
      )}

      {stats.topOpponents.length > 0 && (
        <div className="bg-surface border border-border-subtle rounded-lg p-4 flex flex-col gap-2">
          <p className="text-xs font-semibold text-slate-400 uppercase tracking-wider">Top Opponents</p>
          {stats.topOpponents.map((p) => (
            <div key={p.name} className="flex items-center justify-between">
              <span className="text-sm text-slate-200">{p.name}</span>
              <div className="flex items-center gap-1.5 font-mono text-[9px]">
                <span className="text-emerald-400 font-semibold">{p.wins}W</span>
                <span className="text-red-400 font-semibold">{p.losses}L</span>
                <span className="text-slate-400">{p.count}×</span>
              </div>
            </div>
          ))}
        </div>
      )}

      {stats.tournamentStats.gamesPlayed > 0 && (
        <div className="flex flex-col gap-4">
          <h3 className="text-sm font-bold text-white">Tournament</h3>

          <div className="grid grid-cols-2 gap-3">
            {([
              { label: 'Games', value: stats.tournamentStats.gamesPlayed },
              { label: 'Win Rate', value: `${Math.round((stats.tournamentStats.wins / stats.tournamentStats.gamesPlayed) * 100)}%` },
              { label: 'Wins', value: stats.tournamentStats.wins },
              { label: 'Losses', value: stats.tournamentStats.losses },
            ] as const).map((stat) => (
              <div key={stat.label} className="bg-surface border border-border-subtle rounded-lg p-4">
                <p className="text-xs text-slate-400">{stat.label}</p>
                <p className="text-2xl font-bold text-fg font-mono mt-1">{stat.value}</p>
              </div>
            ))}
          </div>

          {stats.tournamentStats.tournaments.length > 0 && (
            <div className="bg-surface border border-border-subtle rounded-lg p-4 flex flex-col gap-2">
              <p className="text-xs font-semibold text-slate-400 uppercase tracking-wider">
                Tournaments ({stats.tournamentStats.tournaments.length})
              </p>
              {stats.tournamentStats.tournaments.map((t) => (
                <div key={t.name} className="flex justify-between items-center text-sm gap-2">
                  <span className="text-slate-200">{t.name}</span>
                  <div className="flex items-center gap-2 shrink-0 font-mono text-[9px]">
                    <span className="text-emerald-400 font-semibold">{t.wins}W</span>
                    <span className="text-red-400 font-semibold">{t.losses}L</span>
                    <span className="text-slate-400">{t.games} games</span>
                    <span className="text-slate-400">{t.date.split('-').reverse().join('-')}</span>
                  </div>
                </div>
              ))}
            </div>
          )}

          {stats.tournamentStats.topPartners.length > 0 && (
            <div className="bg-surface border border-border-subtle rounded-lg p-4 flex flex-col gap-2">
              <p className="text-xs font-semibold text-slate-400 uppercase tracking-wider">Tournament Partners</p>
              {stats.tournamentStats.topPartners.map((p) => (
                <div key={p.name} className="flex items-center justify-between">
                  <span className="text-sm text-slate-200">{p.name}</span>
                  <div className="flex items-center gap-1.5 font-mono text-[9px]">
                    <span className="text-emerald-400 font-semibold">{p.wins}W</span>
                    <span className="text-slate-400">{p.count}×</span>
                  </div>
                </div>
              ))}
            </div>
          )}

          {stats.tournamentStats.topOpponents.length > 0 && (
            <div className="bg-surface border border-border-subtle rounded-lg p-4 flex flex-col gap-2">
              <p className="text-xs font-semibold text-slate-400 uppercase tracking-wider">Tournament Opponents</p>
              {stats.tournamentStats.topOpponents.map((p) => (
                <div key={p.name} className="flex items-center justify-between">
                  <span className="text-sm text-slate-200">{p.name}</span>
                  <div className="flex items-center gap-1.5 font-mono text-[9px]">
                    <span className="text-emerald-400 font-semibold">{p.wins}W</span>
                    <span className="text-slate-400">{p.count}×</span>
                  </div>
                </div>
              ))}
            </div>
          )}
        </div>
      )}
    </div>
  )
}
