import { useState } from 'react'
import { useListSessions } from '../queries'

export default function SessionListPage() {
  const [dateFilter, setDateFilter] = useState('')

  const { data: sessions = [], isLoading, isError } = useListSessions()

  if (isLoading) return <p className="text-fg-dim text-sm">Loading sessions…</p>
  if (isError) return <p className="text-error text-sm">Failed to load sessions.</p>

  const filtered = dateFilter ? sessions.filter((s) => s.date === dateFilter) : sessions

  return (
    <div className="flex flex-col gap-3">
      <h2 className="text-lg font-bold text-fg">Sessions</h2>

      <div className="flex items-center gap-2">
        <input
          type="date"
          value={dateFilter}
          onChange={(e) => setDateFilter(e.target.value)}
          className="flex-1 bg-elevated border border-border rounded-lg px-3 py-2 text-xs font-sans text-fg scheme-dark"
        />
        {dateFilter && (
          <button
            onClick={() => setDateFilter('')}
            className="text-xs text-fg-dim hover:text-fg border border-border-subtle rounded-lg px-3 py-2 transition-colors"
          >
            Clear
          </button>
        )}
      </div>

      <p className="text-xs font-sans text-fg-dim">
        <span className="text-accent">{filtered.length}</span> session{filtered.length !== 1 ? 's' : ''}
      </p>

      {filtered.length === 0 && (
        <p className="text-fg-dim text-xs font-sans text-center py-8">No sessions on this date.</p>
      )}

      {filtered.length > 0 && (
        <div className="bg-surface border border-border-subtle rounded-lg divide-y divide-border-subtle overflow-hidden">
          {filtered.map((s) => (
            <a
              key={s.id}
              href={`/s/${s.id}`}
              className="flex items-center gap-3 px-4 py-3 hover:bg-elevated transition-colors"
            >
              <div className="flex flex-col min-w-0 flex-1">
                <p className="text-sm font-semibold text-fg truncate">{s.title || 'Untitled Session'}</p>
                <p className="text-xs text-fg-dim mt-0.5 font-sans">{s.date.split('-').reverse().join('-')}</p>
              </div>
              <div className="text-right shrink-0">
                <p className="text-xs text-fg-dim font-sans">{s.playerCount} players</p>
                <p className="text-xs text-fg-dim font-sans">{s.totalGames} games</p>
              </div>
            </a>
          ))}
        </div>
      )}
    </div>
  )
}
