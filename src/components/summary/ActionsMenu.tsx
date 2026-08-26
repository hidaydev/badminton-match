interface ActionsMenuProps {
  actionsOpen: boolean
  onToggle: () => void
  onClose: () => void
  onEnterSwapMode: () => void
  onEnterTeamSwapMode: () => void
  onEnterReplaceMode: () => void
  onEnterChangeMode: () => void
  onEnterSlotSwapMode: () => void
  onEnterAbsentMode: () => void
  onEnterSkipMode: () => void
  hasSwapPlayers?: boolean
  hasSwapTeams?: boolean
  hasReplacePlayer?: boolean
  hasChangePlayer?: boolean
  hasSwapSlots?: boolean
  hasSetAbsent?: boolean
  hasSetSkipped?: boolean
}

export default function ActionsMenu({
  actionsOpen,
  onToggle,
  onClose,
  onEnterSwapMode,
  onEnterTeamSwapMode,
  onEnterReplaceMode,
  onEnterChangeMode,
  onEnterSlotSwapMode,
  onEnterAbsentMode,
  onEnterSkipMode,
  hasSwapPlayers,
  hasSwapTeams,
  hasReplacePlayer,
  hasChangePlayer,
  hasSwapSlots,
  hasSetAbsent,
  hasSetSkipped,
}: ActionsMenuProps) {
  return (
    <div className="relative">
      <button
        onClick={onToggle}
        className="text-xs font-semibold px-3 py-1.5 rounded-lg bg-slate-800/60 border border-slate-700 text-slate-300 hover:text-white transition-colors"
        aria-expanded={actionsOpen}
        aria-haspopup="true"
        aria-label="Actions menu"
      >
        ⋯<span className="hidden sm:inline"> Actions</span>
      </button>
      {actionsOpen && (
        <>
          <div className="fixed inset-0 z-10" onClick={onClose} />
          <div
            className="absolute right-0 top-full mt-1 z-20 bg-slate-900 border border-slate-700 rounded-xl shadow-xl overflow-hidden"
            style={{ minWidth: '160px' }}
            role="menu"
            aria-label="Session actions"
          >
            {hasSwapPlayers && (
              <button
                onClick={onEnterSwapMode}
                className="w-full text-left px-4 py-2.5 text-xs font-medium text-indigo-300 hover:bg-slate-800 transition-colors"
                role="menuitem"
              >
                ⇄ Swap players
              </button>
            )}
            {hasSwapTeams && (
              <button
                onClick={onEnterTeamSwapMode}
                className="w-full text-left px-4 py-2.5 text-xs font-medium text-violet-400 hover:bg-slate-800 transition-colors border-t border-slate-800"
                role="menuitem"
              >
                ⇄ Swap team
              </button>
            )}
            {hasReplacePlayer && (
              <button
                onClick={onEnterReplaceMode}
                className="w-full text-left px-4 py-2.5 text-xs font-medium text-emerald-400 hover:bg-slate-800 transition-colors border-t border-slate-800"
                role="menuitem"
              >
                ↔ Replace player
              </button>
            )}
            {hasChangePlayer && (
              <button
                onClick={onEnterChangeMode}
                className="w-full text-left px-4 py-2.5 text-xs font-medium text-sky-400 hover:bg-slate-800 transition-colors border-t border-slate-800"
                role="menuitem"
              >
                🔄 Change player
              </button>
            )}
            {hasSwapSlots && (
              <button
                onClick={onEnterSlotSwapMode}
                className="w-full text-left px-4 py-2.5 text-xs font-medium text-orange-400 hover:bg-slate-800 transition-colors border-t border-slate-800"
                role="menuitem"
              >
                ↕ Switch slot
              </button>
            )}
            {hasSetAbsent && (
              <button
                onClick={onEnterAbsentMode}
                className="w-full text-left px-4 py-2.5 text-xs font-medium text-red-400 hover:bg-slate-800 transition-colors border-t border-slate-800"
                role="menuitem"
              >
                <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" className="inline mr-1.5 -mt-0.5"><circle cx="12" cy="8" r="4"/><path d="M4 21c0-4 3.6-6 8-6s8 2 8 6"/></svg>
                Mark absent
                <span className="block text-[10px] text-slate-500 font-normal">whole session</span>
              </button>
            )}
            {hasSetSkipped && (
              <button
                onClick={onEnterSkipMode}
                className="w-full text-left px-4 py-2.5 text-xs font-medium text-amber-400 hover:bg-slate-800 transition-colors border-t border-slate-800"
                role="menuitem"
              >
                ⊘ Skip in game
                <span className="block text-[10px] text-slate-500 font-normal">one game only — clears score</span>
              </button>
            )}
          </div>
        </>
      )}
    </div>
  )
}
