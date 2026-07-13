import { useState } from 'react'
import { useListSessions, useDeleteSession } from '../queries'

export default function SessionListPage() {
  const [dateFilter, setDateFilter] = useState('')
  const [deleteTarget, setDeleteTarget] = useState<{ id: string; title: string } | null>(null)

  const { data: sessions = [], isLoading, isError } = useListSessions()
  const deleteSession = useDeleteSession()

  if (isLoading) return <p className="text-slate-400 text-sm">Loading sessions…</p>
  if (isError) return <p className="text-red-400 text-sm">Failed to load sessions.</p>

  const filtered = dateFilter ? sessions.filter((s) => s.date === dateFilter) : sessions

  function handleDelete() {
    if (!deleteTarget) return
    deleteSession.mutate(deleteTarget.id, {
      onSuccess: () => setDeleteTarget(null),
    })
  }

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
        <div
          key={s.id}
          className="flex items-stretch gap-0 bg-slate-900 border border-slate-800 rounded-xl overflow-hidden hover:border-slate-600 transition-colors"
        >
          <a
            href={`/s/${s.id}`}
            className="flex-1 p-4 min-w-0"
          >
            <div className="flex items-start justify-between gap-2">
              <div>
                <p className="text-sm font-semibold text-white">{s.title || 'Untitled Session'}</p>
                <p className="text-xs text-slate-400 mt-0.5 font-mono">{s.date.split('-').reverse().join('-')}</p>
              </div>
              <div className="text-right shrink-0">
                <p className="text-xs text-slate-400">{s.playerCount} players</p>
                <p className="text-xs text-slate-500">{s.totalGames} games</p>
              </div>
            </div>
          </a>
          <button
            onClick={(e) => {
              e.preventDefault()
              setDeleteTarget({ id: s.id, title: s.title || 'Untitled Session' })
            }}
            className="px-3 flex items-center text-slate-600 hover:text-red-400 hover:bg-red-950/30 transition-colors border-l border-slate-800"
            aria-label={`Delete ${s.title || 'session'}`}
          >
            <svg xmlns="http://www.w3.org/2000/svg" width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
              <path d="M3 6h18"/><path d="M19 6v14c0 1-1 2-2 2H7c-1 0-2-1-2-2V6"/><path d="M8 6V4c0-1 1-2 2-2h4c1 0 2 1 2 2v2"/>
            </svg>
          </button>
        </div>
      ))}

      {/* Delete confirmation modal */}
      {deleteTarget && (
        <div className="fixed inset-0 z-50 flex items-center justify-center p-4" onClick={() => setDeleteTarget(null)}>
          <div className="absolute inset-0 bg-black/60" />
          <div
            className="relative bg-slate-900 border border-slate-700 rounded-2xl p-5 max-w-sm w-full shadow-xl"
            onClick={(e) => e.stopPropagation()}
          >
            <p className="text-sm font-bold text-white mb-1">Delete session?</p>
            <p className="text-xs text-slate-400 mb-4">
              <span className="text-slate-300 font-medium">{deleteTarget.title}</span> will be permanently deleted.
              This cannot be undone.
            </p>
            <div className="flex gap-2 justify-end">
              <button
                onClick={() => setDeleteTarget(null)}
                className="text-xs font-medium px-4 py-2 rounded-lg bg-slate-800 text-slate-300 hover:text-white transition-colors"
              >
                Cancel
              </button>
              <button
                onClick={handleDelete}
                disabled={deleteSession.isPending}
                className="text-xs font-bold px-4 py-2 rounded-lg bg-red-600 hover:bg-red-500 text-white transition-colors disabled:opacity-50 flex items-center gap-1.5"
              >
                {deleteSession.isPending && (
                  <svg className="animate-spin w-3 h-3" viewBox="0 0 24 24" fill="none">
                    <circle className="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" strokeWidth="4" />
                    <path className="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4z" />
                  </svg>
                )}
                {deleteSession.isPending ? 'Deleting…' : 'Delete'}
              </button>
            </div>
          </div>
        </div>
      )}
    </div>
  )
}
