import { useEffect, useState } from 'react'
import { useNavigate } from 'react-router-dom'
import { listPlayers, type PlayerSummary } from '../utils/cloudSync'

export default function PlayerHistoryPage() {
  const [players, setPlayers] = useState<PlayerSummary[]>([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)
  const navigate = useNavigate()

  useEffect(() => {
    listPlayers()
      .then(setPlayers)
      .catch((e: Error) => setError(e.message))
      .finally(() => setLoading(false))
  }, [])

  if (loading) return <p className="text-slate-400 text-sm">Loading players…</p>
  if (error) return <p className="text-red-400 text-sm">Error: {error}</p>

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
          className="bg-slate-900 border border-slate-800 rounded-xl p-4 flex items-center justify-between hover:border-slate-600 transition-colors text-left w-full"
        >
          <div>
            <p className="text-sm font-semibold text-white">{p.name}</p>
            <p className="text-xs text-slate-400 mt-0.5">Tier {(['A','B','C','D'])[p.tier - 1]} · {p.gender === 'M' ? 'Male' : 'Female'}</p>
          </div>
          <span className="text-slate-600 text-lg">›</span>
        </button>
      ))}
    </div>
  )
}
