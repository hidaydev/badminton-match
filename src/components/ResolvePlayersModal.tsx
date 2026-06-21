import { useState, useEffect, useMemo } from 'react'
import type { Player } from '../store'
import type { PlayerSummary } from '../queries'

interface ResolveEntry {
  player: Player
  mode: 'new' | 'merge'
  mergeTarget: string | null
}

interface ResolveResult {
  registerNew: { name: string }[]
  registerAlias: { alias: string; canonical: string }[]
  renameMap: Map<string, string>
}

interface ResolvePlayersModalProps {
  open: boolean
  localPlayers: Player[]
  knownPlayers: PlayerSummary[]
  onResolve: (result: ResolveResult) => void
  onCancel: () => void
}

export function isKnownPlayer(name: string, knownPlayers: PlayerSummary[]): boolean {
  const normalized = name.trim().toLowerCase().replace(/\s+/g, ' ')
  return knownPlayers.some((kp) => {
    const kn = kp.name.trim().toLowerCase().replace(/\s+/g, ' ')
    return kn === normalized
  })
}

export function findUnresolvedPlayers(localPlayers: Player[], knownPlayers: PlayerSummary[]): Player[] {
  return localPlayers.filter((p) => !isKnownPlayer(p.name, knownPlayers))
}

export default function ResolvePlayersModal({
  open,
  localPlayers,
  knownPlayers,
  onResolve,
  onCancel,
}: ResolvePlayersModalProps) {
  const unresolved = useMemo(
    () => findUnresolvedPlayers(localPlayers, knownPlayers),
    [localPlayers, knownPlayers],
  )

  const [entries, setEntries] = useState<Record<string, ResolveEntry>>({})

  useEffect(() => {
    if (!open) return
    const next: Record<string, ResolveEntry> = {}
    for (const p of unresolved) {
      next[p.id] = {
        player: p,
        mode: 'new',
        mergeTarget: null,
      }
    }
    setEntries(next)
  }, [open, unresolved])

  if (!open) return null

  function setMode(playerId: string, mode: 'new' | 'merge') {
    setEntries((prev) => ({
      ...prev,
      [playerId]: { ...prev[playerId], mode },
    }))
  }

  function setMergeTarget(playerId: string, target: string) {
    setEntries((prev) => ({
      ...prev,
      [playerId]: { ...prev[playerId], mergeTarget: target },
    }))
  }

  function handleConfirm() {
    const registerNew: { name: string }[] = []
    const registerAlias: { alias: string; canonical: string }[] = []
    const renameMap = new Map<string, string>()

    for (const p of unresolved) {
      const entry = entries[p.id]
      if (!entry) continue
      if (entry.mode === 'new') {
        registerNew.push({ name: p.name })
      } else {
        const target = entry.mergeTarget
        if (!target) {
          registerNew.push({ name: p.name })
        } else {
          registerAlias.push({ alias: p.name, canonical: target })
          renameMap.set(p.id, target)
        }
      }
    }

    onResolve({ registerNew, registerAlias, renameMap })
  }

  const list = Object.values(entries)
  const allResolved = list.length > 0 && list.every((e) => e.mode === 'new' || (e.mode === 'merge' && e.mergeTarget))

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/60 px-4">
      <div className="bg-slate-900 border border-slate-700 rounded-2xl p-6 max-w-lg w-full flex flex-col gap-4 shadow-2xl max-h-[85vh] overflow-auto">
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
                  "{entry.player.name}" will be registered as an alias of{' '}
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
