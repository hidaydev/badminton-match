import { useState } from 'react'
import type { Player } from '../store'
import type { PlayerSummary } from '../queries'
import type { ResolveEntry, ResolveResult } from '../utils/resolvePlayers'
import { buildResolveResult } from '../utils/resolvePlayers'

interface ResolvePlayersModalProps {
  open: boolean
  localPlayers: Player[]
  knownPlayers: PlayerSummary[]
  onResolve: (result: ResolveResult) => void
  onCancel: () => void
}

export default function ResolvePlayersModal({
  open,
  localPlayers,
  knownPlayers,
  onResolve,
  onCancel,
}: ResolvePlayersModalProps) {
  const [entries, setEntries] = useState<Record<string, ResolveEntry>>({})

  if (!open) return null

  const unresolved = localPlayers.filter((p) => {
    const normalized = p.name.trim().toLowerCase().replace(/\s+/g, ' ')
    return !knownPlayers.some((kp) => {
      const kn = kp.name.trim().toLowerCase().replace(/\s+/g, ' ')
      return kn === normalized
    })
  })

  const currentEntries: Record<string, ResolveEntry> = {}
  for (const p of unresolved) {
    currentEntries[p.id] = entries[p.id] ?? {
      player: p,
      mode: 'new' as const,
      mergeTarget: null,
    }
  }

  function setMode(playerId: string, mode: 'new' | 'merge') {
    setEntries((prev) => ({
      ...prev,
      [playerId]: { ...currentEntries[playerId], mode },
    }))
  }

  function setMergeTarget(playerId: string, target: string) {
    setEntries((prev) => ({
      ...prev,
      [playerId]: { ...currentEntries[playerId], mergeTarget: target },
    }))
  }

  function handleConfirm() {
    onResolve(buildResolveResult(unresolved, currentEntries))
  }

  const list = Object.values(currentEntries)
  const allResolved = list.length > 0 && list.every((e) => e.mode === 'new' || (e.mode === 'merge' && e.mergeTarget))

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/60 px-4">
      <div className="bg-slate-900 border border-slate-700 rounded-2xl p-6 max-w-lg w-full flex flex-col gap-4 shadow-2xl max-h-screen overflow-auto">
        <div className="flex flex-col gap-1">
          <h2 className="text-white font-bold text-lg">Resolve new players</h2>
          <p className="text-slate-400 text-sm">
            {list.length} player{list.length > 1 ? 's' : ''} not found in the database.
            Choose <span className="text-emerald-400 font-medium">Add new</span> to register
            them, or <span className="text-indigo-400 font-medium">Merge</span> to link
            them to an existing player.
          </p>
        </div>

        <div className="flex flex-col gap-3">
          {list.map((entry) => (
            <div key={entry.player.id} className="bg-slate-800 border border-slate-700 rounded-xl px-3 py-2.5 flex flex-col gap-2">
              <span className="text-sm font-semibold text-white">{entry.player.name}</span>
              <div className="flex gap-1.5">
                <button
                  onClick={() => setMode(entry.player.id, 'new')}
                  className={`flex-1 py-1.5 rounded-lg text-xs font-semibold transition-colors ${
                    entry.mode === 'new'
                      ? 'bg-emerald-700 text-white border border-emerald-500'
                      : 'bg-slate-700 text-slate-400 border border-slate-600 hover:text-slate-200'
                  }`}
                >
                  + Add new
                </button>
                <button
                  onClick={() => setMode(entry.player.id, 'merge')}
                  className={`flex-1 py-1.5 rounded-lg text-xs font-semibold transition-colors ${
                    entry.mode === 'merge'
                      ? 'bg-indigo-700 text-white border border-indigo-500'
                      : 'bg-slate-700 text-slate-400 border border-slate-600 hover:text-slate-200'
                  }`}
                >
                  ⇄ Merge
                </button>
              </div>
              {entry.mode === 'merge' && (
                <select
                  value={entry.mergeTarget ?? ''}
                  onChange={(e) => setMergeTarget(entry.player.id, e.target.value)}
                  className="w-full bg-slate-900 border border-slate-600 rounded-lg px-2 py-1.5 text-xs text-white focus:outline-none focus:border-indigo-500"
                >
                  <option value="">— Select existing player —</option>
                  {knownPlayers.map((kp) => (
                    <option key={kp.name} value={kp.name}>
                      {kp.name} ({kp.gender}, Tier {kp.tier})
                    </option>
                  ))}
                </select>
              )}
              {entry.mode === 'merge' && entry.mergeTarget && (
                <p className="text-[10px] text-slate-500">
                  &quot;{entry.player.name}&quot; will be registered as an alias of{' '}
                  <span className="text-indigo-400 font-medium">{entry.mergeTarget}</span>.
                  Future sessions with this name will auto-resolve.
                </p>
              )}
            </div>
          ))}
        </div>

        <div className="flex gap-2 pt-1">
          <button
            onClick={onCancel}
            className="flex-1 py-2 rounded-xl text-sm font-medium bg-slate-800 hover:bg-slate-700 text-slate-300 hover:text-white transition-colors"
          >
            Cancel
          </button>
          <button
            onClick={handleConfirm}
            disabled={!allResolved}
            className="flex-1 py-2 rounded-xl text-sm font-bold bg-indigo-600 hover:bg-indigo-500 text-white transition-colors disabled:opacity-40 disabled:cursor-not-allowed"
          >
            Confirm
          </button>
        </div>
      </div>
    </div>
  )
}
