import { t } from '@/i18n'
import { useEscapeKey } from '../../hooks/useEscapeKey'
import Icon from '../Icon'

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
  // A menu, not a dialog: it owns Escape only while it is open. Its handler sits
  // above the SummaryModal one on the global stack, so one press closes the menu
  // and leaves the modal alone.
  useEscapeKey(onClose, actionsOpen)

  return (
    <div className="relative">
      <button
        onClick={onToggle}
        className="text-xs font-semibold px-3 py-1.5 rounded-lg bg-slate-800/60 border border-slate-700 text-slate-300 hover:text-white transition-colors hit44"
        aria-expanded={actionsOpen}
        aria-haspopup="true"
        aria-label={t('summary.actions')}
      >
        ⋯<span className="hidden sm:inline">{' '}{t('legacy.actions.label')}</span>
      </button>
      {actionsOpen && (
        <>
          <div className="fixed inset-0 z-10" onClick={onClose} aria-hidden="true" />
          <div
            className="absolute right-0 top-full mt-1 z-20 bg-slate-900 border border-slate-700 rounded-xl shadow-xl overflow-hidden"
            style={{ minWidth: '160px' }}
            role="menu"
            aria-label={t('summary.actionsSession')}
          >
            {hasSwapPlayers && (
              <button
                onClick={onEnterSwapMode}
                className="w-full text-left px-4 py-2.5 text-xs font-medium text-indigo-300 hover:bg-slate-800 transition-colors hit44"
                role="menuitem"
              >
                {t('legacy.actions.swapPlayers')}</button>
            )}
            {hasSwapTeams && (
              <button
                onClick={onEnterTeamSwapMode}
                className="w-full text-left px-4 py-2.5 text-xs font-medium text-sky-400 hover:bg-slate-800 transition-colors border-t border-slate-800 hit44"
                role="menuitem"
              >
                {t('legacy.actions.swapTeam')}</button>
            )}
            {hasReplacePlayer && (
              <button
                onClick={onEnterReplaceMode}
                className="w-full text-left px-4 py-2.5 text-xs font-medium text-emerald-400 hover:bg-slate-800 transition-colors border-t border-slate-800 hit44"
                role="menuitem"
              >
                {t('legacy.actions.replacePlayer')}<span className="block text-[10px] text-slate-400 font-normal">{t('legacy.actions.replacePlayerHint')}</span>
              </button>
            )}
            {hasChangePlayer && (
              <button
                onClick={onEnterChangeMode}
                className="w-full text-left px-4 py-2.5 text-xs font-medium text-sky-400 hover:bg-slate-800 transition-colors border-t border-slate-800 hit44"
                role="menuitem"
              >
                {t('legacy.actions.changePlayer')}<span className="block text-[10px] text-slate-400 font-normal">{t('legacy.actions.changePlayerHint')}</span>
              </button>
            )}
            {hasSwapSlots && (
              <button
                onClick={onEnterSlotSwapMode}
                className="w-full text-left px-4 py-2.5 text-xs font-medium text-amber-400 hover:bg-slate-800 transition-colors border-t border-slate-800 hit44"
                role="menuitem"
              >
                {t('legacy.actions.switchSlot')}</button>
            )}
            {hasSetAbsent && (
              <button
                onClick={onEnterAbsentMode}
                className="w-full text-left px-4 py-2.5 text-xs font-medium text-red-400 hover:bg-slate-800 transition-colors border-t border-slate-800 hit44"
                role="menuitem"
              >
                <Icon name="user" size={14} className="inline mr-1.5 -mt-0.5" />
                {t('legacy.markAbsent')}
                <span className="block text-[10px] text-slate-400 font-normal">{t('legacy.actions.wholeSession')}</span>
              </button>
            )}
            {hasSetSkipped && (
              <button
                onClick={onEnterSkipMode}
                className="w-full text-left px-4 py-2.5 text-xs font-medium text-amber-400 hover:bg-slate-800 transition-colors border-t border-slate-800 hit44"
                role="menuitem"
              >
                {t('legacy.actions.skipInGame')}<span className="block text-[10px] text-slate-400 font-normal">{t('legacy.actions.skipInGameHint')}</span>
              </button>
            )}
          </div>
        </>
      )}
    </div>
  )
}
