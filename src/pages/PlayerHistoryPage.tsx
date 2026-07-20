import { useNavigate } from 'react-router-dom'
import { useListPlayers } from '../queries'

export default function PlayerHistoryPage() {
  const navigate = useNavigate()

  const { data: players = [], isLoading, isError } = useListPlayers()

  if (isLoading) return <p className="text-slate-400 text-sm">Loading players…</p>
  if (isError) return <p className="text-red-400 text-sm">Failed to load players.</p>

  return (
    <div className="flex flex-col gap-3">
      <h2 className="text-lg font-bold text-white">Player History</h2>
      {players.length === 0 && (
        <p className="text-slate-400 text-sm">No players found.</p>
      )}
      {players.map((p) => (
        <button
          key={p.name}
          onClick={() => navigate(`/player-history/${encodeURIComponent(p.name)}`)}
          className="bg-surface border border-border-subtle rounded-xl p-4 flex items-center justify-between hover:border-slate-600 transition-colors text-left w-full"
        >
          <div className="flex items-center gap-2">
            <p className="text-sm font-semibold text-white">{p.name}</p>
            <p className="text-xs text-slate-400">{p.gender === 'M' ? 'M' : 'F'}</p>
          </div>
          <span className="text-slate-400 text-lg">›</span>
        </button>
      ))}
    </div>
  )
}
