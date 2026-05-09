import { useState } from 'react'
import { useTournamentStore, type GroupId } from '../../store/tournament'

export default function GroupAssignment() {
  const pairs = useTournamentStore((s) => s.pairs)
  const groups = useTournamentStore((s) => s.groups)
  const addPairToGroup = useTournamentStore((s) => s.addPairToGroup)
  const removePairFromGroup = useTournamentStore((s) => s.removePairFromGroup)
  const lockGroups = useTournamentStore((s) => s.lockGroups)

  const [picking, setPicking] = useState<string | null>(null)

  const assignedIds = new Set(Object.values(groups).flat())
  const unassigned = pairs.filter((p) => !assignedIds.has(p.id))
  const allFull = (['A','B','C','D'] as GroupId[]).every((g) => groups[g].length === 4)

  const getPairName = (id: string) => pairs.find((p) => p.id === id)?.name ?? id

  return (
    <div className="space-y-4">
      <p className="text-xs text-slate-400 text-center">
        Tap a pair below to assign it to a group
      </p>

      {/* 2×2 group grid */}
      <div className="grid grid-cols-2 gap-3">
        {(['A','B','C','D'] as GroupId[]).map((g) => (
          <div key={g} className="bg-slate-800 rounded-xl overflow-hidden">
            <div className="bg-amber-900 px-3 py-1.5 flex justify-between items-center">
              <span className="text-yellow-300 text-xs font-bold">GROUP {g}</span>
              <span className="text-yellow-600 text-xs">{groups[g].length}/4</span>
            </div>
            <div className="p-2 min-h-[80px] flex flex-col gap-1.5">
              {groups[g].map((id) => (
                <div key={id} className="flex items-center justify-between bg-slate-900 rounded-lg px-2 py-1.5 text-xs text-slate-300">
                  <span className="truncate">{getPairName(id)}</span>
                  <button
                    onClick={() => removePairFromGroup(id)}
                    className="text-slate-600 hover:text-slate-400 ml-2 shrink-0"
                  >
                    ×
                  </button>
                </div>
              ))}
              {groups[g].length < 4 && (
                <div className="text-xs text-slate-600 text-center py-1">
                  {4 - groups[g].length} slot{4 - groups[g].length !== 1 ? 's' : ''} left
                </div>
              )}
            </div>
          </div>
        ))}
      </div>

      {/* Unassigned pool */}
      {unassigned.length > 0 && (
        <div>
          <p className="text-xs text-slate-500 mb-2">Unassigned — tap to assign</p>
          <div className="flex flex-wrap gap-2">
            {unassigned.map((p) => (
              <button
                key={p.id}
                onClick={() => setPicking(p.id)}
                className="bg-slate-700 hover:bg-slate-600 text-slate-200 text-xs rounded-lg px-3 py-2 font-medium"
              >
                {p.name}
              </button>
            ))}
          </div>
        </div>
      )}

      {/* Confirm button */}
      {allFull && (
        <button
          onClick={lockGroups}
          className="w-full py-3 rounded-xl bg-yellow-400 text-slate-900 font-bold text-sm mt-2"
        >
          Confirm Groups
        </button>
      )}

      {/* Group picker bottom sheet */}
      {picking && (
        <div className="fixed inset-0 bg-black/70 z-50 flex items-end justify-center p-4">
          <div className="bg-slate-800 rounded-2xl w-full max-w-sm p-5">
            <p className="text-sm text-slate-300 font-semibold text-center mb-1">
              Assign to group
            </p>
            <p className="text-xs text-slate-500 text-center mb-4">
              {getPairName(picking)}
            </p>
            <div className="grid grid-cols-4 gap-2 mb-4">
              {(['A','B','C','D'] as GroupId[]).map((g) => (
                <button
                  key={g}
                  disabled={groups[g].length >= 4}
                  onClick={() => { addPairToGroup(picking, g); setPicking(null) }}
                  className="py-4 rounded-xl bg-amber-900 text-yellow-300 font-bold text-lg disabled:opacity-30 disabled:cursor-not-allowed hover:bg-amber-800"
                >
                  {g}
                </button>
              ))}
            </div>
            <button
              onClick={() => setPicking(null)}
              className="w-full py-2.5 rounded-xl bg-slate-700 text-slate-300 text-sm"
            >
              Cancel
            </button>
          </div>
        </div>
      )}
    </div>
  )
}
