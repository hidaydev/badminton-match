import { useState } from 'react'
import type { GroupId, TournamentPair } from '../../utils/tournament'

const GROUP_IDS: GroupId[] = ['A', 'B', 'C', 'D']

const GROUP_HEAD_CLASS: Record<GroupId, string> = {
  A: 'bg-amber-900 text-yellow-300',
  B: 'bg-blue-900 text-blue-300',
  C: 'bg-green-900 text-green-300',
  D: 'bg-purple-900 text-purple-300',
}

interface ActiveSlot {
  groupId: GroupId
  slotIndex: number
}

interface Props {
  pairs: TournamentPair[]
  groups: Record<GroupId, (string | null)[]>
  onAddPairToGroup: (pairId: string, groupId: GroupId, slotIndex: number) => void
  onRemovePairFromGroup: (pairId: string) => void
  onConfirmGroups: () => void
  isLoading?: boolean
}

export default function GroupAssignment({
  pairs,
  groups,
  onAddPairToGroup,
  onRemovePairFromGroup,
  onConfirmGroups,
  isLoading,
}: Props) {
  const [activeSlot, setActiveSlot] = useState<ActiveSlot | null>(null)

  const assignedIds = new Set(Object.values(groups).flat().filter(Boolean) as string[])
  const unassigned = pairs.filter((p) => !assignedIds.has(p.id))
  const allFull = GROUP_IDS.every((g) => groups[g].every((id) => id !== null))

  const getPairName = (id: string) => pairs.find((p) => p.id === id)?.name ?? id

  const slotNumber = (groupId: GroupId, slotIndex: number) =>
    GROUP_IDS.indexOf(groupId) * 4 + slotIndex + 1

  const isActive = (groupId: GroupId, slotIndex: number) =>
    activeSlot?.groupId === groupId && activeSlot?.slotIndex === slotIndex

  const handleSlotTap = (groupId: GroupId, slotIndex: number) => {
    if (isActive(groupId, slotIndex)) {
      setActiveSlot(null)
    } else {
      setActiveSlot({ groupId, slotIndex })
    }
  }

  const handlePairTap = (pairId: string) => {
    if (!activeSlot) return
    onAddPairToGroup(pairId, activeSlot.groupId, activeSlot.slotIndex)
    setActiveSlot(null)
  }

  const activeLabel = activeSlot
    ? `Slot #${slotNumber(activeSlot.groupId, activeSlot.slotIndex)} · Group ${activeSlot.groupId} selected — pick a pair:`
    : null

  return (
    <div className="space-y-4">
      <p className="text-xs text-slate-400 text-center">
        Tap an empty slot, then tap a pair to assign
      </p>

      {/* 2×2 group grid */}
      <div className="grid grid-cols-2 gap-3">
        {GROUP_IDS.map((g) => (
          <div key={g} className="bg-slate-800 rounded-xl overflow-hidden">
            <div className={`px-3 py-1.5 flex justify-between items-center ${GROUP_HEAD_CLASS[g]}`}>
              <span className="text-xs font-bold">GROUP {g}</span>
              <span className="text-xs opacity-70">{groups[g].filter(Boolean).length}/4</span>
            </div>
            <div className="p-2 flex flex-col gap-1.5">
              {[0, 1, 2, 3].map((slotIdx) => {
                const pairId = groups[g][slotIdx]
                const num = slotNumber(g, slotIdx)
                const active = isActive(g, slotIdx)

                if (pairId) {
                  return (
                    <div
                      key={slotIdx}
                      className="flex items-center gap-1.5 bg-slate-900 border border-slate-700 rounded-lg px-2 py-1.5"
                    >
                      <span className="text-[8px] font-bold text-slate-400" style={{ minWidth: '18px' }}>
                        #{num}
                      </span>
                      <span className="text-xs text-slate-300 truncate flex-1">
                        {getPairName(pairId)}
                      </span>
                      <button
                        onClick={() => onRemovePairFromGroup(pairId)}
                        aria-label={`Remove ${getPairName(pairId)}`}
                        className="text-slate-400 hover:text-slate-400 shrink-0 ml-1"
                      >
                        ×
                      </button>
                    </div>
                  )
                }

                return (
                  <button
                    key={slotIdx}
                    onClick={() => handleSlotTap(g, slotIdx)}
                    className={[
                      'flex items-center gap-1.5 rounded-lg px-2 py-1.5 text-left transition-all',
                      active
                        ? 'bg-amber-400/10 border border-amber-400 ring-2 ring-amber-400/30'
                        : 'bg-slate-900 border border-dashed border-slate-700 hover:border-slate-500',
                    ].join(' ')}
                  >
                    <span
                      className={`text-[8px] font-bold ${active ? 'text-amber-400' : 'text-slate-400'}`}
                      style={{ minWidth: '18px' }}
                    >
                      #{num}
                    </span>
                    <span className={`text-xs ${active ? 'text-amber-300 font-semibold' : 'text-slate-400'}`}>
                      {active ? '← pick a pair below' : 'tap to fill'}
                    </span>
                  </button>
                )
              })}
            </div>
          </div>
        ))}
      </div>

      {/* Unassigned pool */}
      {unassigned.length > 0 && (
        <div>
          <p className={`text-xs mb-2 ${activeSlot ? 'text-yellow-400 font-semibold' : 'text-slate-400'}`}>
            {activeLabel ?? 'Unassigned — tap a slot above first'}
          </p>
          <div className="flex flex-wrap gap-2">
            {unassigned.map((p) => (
              <button
                key={p.id}
                onClick={() => handlePairTap(p.id)}
                disabled={!activeSlot}
                className={[
                  'text-xs rounded-lg px-3 py-2 font-medium transition-all',
                  activeSlot
                    ? 'bg-slate-900 text-yellow-300 border border-yellow-400 font-semibold hover:bg-slate-800'
                    : 'bg-slate-700 text-slate-400 border border-slate-600 cursor-default',
                ].join(' ')}
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
          onClick={onConfirmGroups}
          disabled={isLoading}
          className="w-full py-3 rounded-xl bg-yellow-400 text-slate-900 font-bold text-sm mt-2 disabled:opacity-60 flex items-center justify-center gap-2"
        >
          {isLoading && (
            <svg className="animate-spin w-4 h-4 shrink-0" viewBox="0 0 24 24" fill="none">
              <circle className="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" strokeWidth="4" />
              <path className="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4z" />
            </svg>
          )}
          {isLoading ? 'Confirming…' : 'Confirm Groups'}
        </button>
      )}
    </div>
  )
}
