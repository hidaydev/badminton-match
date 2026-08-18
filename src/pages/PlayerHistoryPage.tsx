import { useNavigate } from 'react-router-dom'
import { useListPlayers } from '../queries'

export default function PlayerHistoryPage() {
  const navigate = useNavigate()

  const { data: players = [], isLoading, isError } = useListPlayers()

  if (isLoading) return <p className="text-fg-dim text-sm">Loading players…</p>
  if (isError) return <p className="text-error text-sm">Failed to load players.</p>

  return (
    <div className="flex flex-col gap-3">
      <h2 className="text-lg font-bold text-fg">Player History</h2>
      {players.length === 0 && (
        <p className="text-fg-dim text-sm">No players found.</p>
      )}
      {players.length > 0 && (
        <div className="bg-surface border border-border-subtle rounded-lg divide-y divide-border-subtle overflow-hidden">
          {players.map((p) => (
            <button
              key={p.name}
              onClick={() => navigate(`/player-history/${encodeURIComponent(p.name)}`)}
              className="w-full px-4 py-3 flex items-center justify-between hover:bg-elevated transition-colors text-left"
            >
              <div className="flex items-center gap-2 min-w-0">
                <p className="text-sm font-semibold text-fg truncate">{p.name}</p>
                <p className="text-xs text-fg-dim font-mono">{p.gender === 'M' ? 'M' : 'F'}</p>
              </div>
              <span className="text-fg-dim">›</span>
            </button>
          ))}
        </div>
      )}
    </div>
  )
}
