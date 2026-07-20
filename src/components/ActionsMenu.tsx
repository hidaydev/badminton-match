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
  onLockSession: () => void
  hasSwapPlayers?: boolean
  hasSwapTeams?: boolean
  hasReplacePlayer?: boolean
  hasChangePlayer?: boolean
  hasSwapSlots?: boolean
  hasSetAbsent?: boolean
  hasLock?: boolean
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
  onLockSession,
  hasSwapPlayers,
  hasSwapTeams,
  hasReplacePlayer,
  hasChangePlayer,
  hasSwapSlots,
  hasSetAbsent,
  hasLock,
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
                👤 Mark absent
              </button>
            )}
            {hasLock && (
              <button
                onClick={onLockSession}
                className="w-full text-left px-4 py-2.5 text-xs font-medium text-amber-400 hover:bg-slate-800 transition-colors border-t border-slate-800"
                role="menuitem"
              >
                🔒 Lock session
              </button>
            )}
          </div>
        </>
      )}
    </div>
  )
}
