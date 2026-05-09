import { useParams, useNavigate } from 'react-router-dom'
import { useQuery } from '@tanstack/react-query'
import { getPlayerStats, type PlayerStats } from '../utils/cloudSync'

export default function PlayerDetailPage() {
  const { name } = useParams<{ name: string }>()
  const navigate = useNavigate()

  const { data: stats, isLoading, isError } = useQuery<PlayerStats>({
    queryKey: ['player', name],
    queryFn: () => getPlayerStats(decodeURIComponent(name!)),
    enabled: !!name,
  })

  if (isLoading) return <p className="text-slate-400 text-sm">Loading stats…</p>
  if (isError) return <p className="text-red-400 text-sm">Failed to load stats.</p>
  if (!stats) return null

  const winRate = stats.gamesPlayed > 0
    ? Math.round((stats.wins / stats.gamesPlayed) * 100)
    : 0

  return (
    <div className="flex flex-col gap-4">
      <button
        onClick={() => navigate(-1)}
        className="text-xs text-slate-400 hover:text-slate-200 self-start transition-colors"
      >
        ← Back
      </button>

      <h2 className="text-xl font-bold text-white">{stats.name}</h2>

      <div className="grid grid-cols-2 gap-3">
        {([
          { label: 'Games', value: stats.gamesPlayed },
          { label: 'Win Rate', value: `${winRate}%` },
          { label: 'Wins', value: stats.wins },
          { label: 'Losses', value: stats.losses },
        ] as const).map((stat) => (
          <div key={stat.label} className="bg-slate-900 border border-slate-800 rounded-xl p-4">
            <p className="text-xs text-slate-400">{stat.label}</p>
            <p className="text-2xl font-bold text-white mt-1">{stat.value}</p>
          </div>
        ))}
      </div>

      {stats.sessions.length > 0 && (
        <div className="bg-slate-900 border border-slate-800 rounded-xl p-4 flex flex-col gap-2">
          <p className="text-xs font-semibold text-slate-400 uppercase tracking-wider">
            Sessions ({stats.sessions.length})
          </p>
          {stats.sessions.map((s) => (
            <div key={s.id} className="flex justify-between items-center text-sm gap-2">
              <span className={s.absent ? 'text-slate-500 line-through' : 'text-slate-200'}>{s.title || 'Untitled'}</span>
              <div className="flex items-center gap-2 shrink-0">
                {s.absent && <span className="text-[10px] text-slate-600">absent</span>}
                <span className="text-slate-500">{s.date.split('-').reverse().join('-')}</span>
              </div>
            </div>
          ))}
        </div>
      )}

      {stats.topPartners.length > 0 && (
        <div className="bg-slate-900 border border-slate-800 rounded-xl p-4 flex flex-col gap-2">
          <p className="text-xs font-semibold text-slate-400 uppercase tracking-wider">Top Partners</p>
          {stats.topPartners.map((p) => (
            <div key={p.name} className="flex items-center justify-between">
              <span className="text-sm text-slate-200">{p.name}</span>
              <div className="flex items-center gap-1.5 font-mono text-[9px]">
                <span className="text-emerald-400 font-semibold">{p.wins}W</span>
                <span className="text-red-400 font-semibold">{p.losses}L</span>
                <span className="text-slate-500">{p.count}×</span>
              </div>
            </div>
          ))}
        </div>
      )}

      {stats.topOpponents.length > 0 && (
        <div className="bg-slate-900 border border-slate-800 rounded-xl p-4 flex flex-col gap-2">
          <p className="text-xs font-semibold text-slate-400 uppercase tracking-wider">Top Opponents</p>
          {stats.topOpponents.map((p) => (
            <div key={p.name} className="flex items-center justify-between">
              <span className="text-sm text-slate-200">{p.name}</span>
              <div className="flex items-center gap-1.5 font-mono text-[9px]">
                <span className="text-emerald-400 font-semibold">{p.wins}W</span>
                <span className="text-red-400 font-semibold">{p.losses}L</span>
                <span className="text-slate-500">{p.count}×</span>
              </div>
            </div>
          ))}
        </div>
      )}
    </div>
  )
}
