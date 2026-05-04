import { useEffect, useState } from 'react'
import { listSessions, type SessionMeta } from '../utils/cloudSync'

export default function SessionListPage() {
  const [sessions, setSessions] = useState<SessionMeta[]>([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)
  const [dateFilter, setDateFilter] = useState('')

  useEffect(() => {
    listSessions()
      .then(setSessions)
      .catch((e: Error) => setError(e.message))
      .finally(() => setLoading(false))
  }, [])

  if (loading) return <p className="text-slate-400 text-sm">Loading sessions…</p>
  if (error) return <p className="text-red-400 text-sm">Error: {error}</p>

  const filtered = dateFilter ? sessions.filter((s) => s.date === dateFilter) : sessions

  return (
    <div className="flex flex-col gap-3">
      <h2 className="text-lg font-bold text-white">Sessions</h2>

      <div className="flex items-center gap-2">
        <input
          type="date"
          value={dateFilter}
          onChange={(e) => setDateFilter(e.target.value)}
          className="flex-1 bg-slate-900 border border-slate-800 rounded-lg px-3 py-2 text-xs font-mono text-slate-300 [color-scheme:dark]"
        />
        {dateFilter && (
          <button
            onClick={() => setDateFilter('')}
            className="text-xs text-slate-500 hover:text-slate-300 border border-slate-800 rounded-lg px-3 py-2 transition-colors"
          >
            Clear
          </button>
        )}
      </div>

      <p className="text-xs font-mono text-slate-500">
        <span className="text-indigo-400">{filtered.length}</span> session{filtered.length !== 1 ? 's' : ''}
      </p>

      {filtered.length === 0 && (
        <p className="text-slate-600 text-xs font-mono text-center py-8">No sessions on this date.</p>
      )}

      {filtered.map((s) => (
        <a
          key={s.id}
          href={`/s/${s.id}`}
          className="block bg-slate-900 border border-slate-800 rounded-xl p-4 hover:border-slate-600 transition-colors"
        >
          <div className="flex items-start justify-between gap-2">
            <div>
              <p className="text-sm font-semibold text-white">{s.title || 'Untitled Session'}</p>
              <p className="text-xs text-slate-400 mt-0.5 font-mono">{s.date}</p>
            </div>
            <div className="text-right shrink-0">
              <p className="text-xs text-slate-400">{s.playerCount} players</p>
              <p className="text-xs text-slate-500">{s.totalGames} games</p>
            </div>
          </div>
        </a>
      ))}
    </div>
  )
}
