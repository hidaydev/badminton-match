import type { SwapTarget, ChangeTarget } from '../../utils/swap'

export type PlayerChipMode = 'idle' | 'swap' | 'absent' | 'skip' | 'replace' | 'slotSwap' | 'teamSwap' | 'change'

interface PlayerChipRendererProps {
  /** Display name of the player */
  playerName: string
  /** Which team this player belongs to */
  team: 'A' | 'B'
  /** Position within the team (0 or 1) */
  position: 0 | 1
  /** Current modal mode */
  mode: PlayerChipMode
  /** Whether the game is already played */
  done: boolean
  /** Pending swap target (if any) */
  pendingSwap: { t1: SwapTarget; t2: SwapTarget } | null
  /** Whether this specific chip is selected for swap */
  isSelected: boolean
  /** Whether this player is absent */
  isAbsent: boolean
  /** Whether this game has a saved score (blocks change mode) */
  hasScore: boolean
  /** Current replace target (for highlighting) */
  replaceTarget: string | null
  /** Current change target (for highlighting) */
  changeTarget: ChangeTarget | null
  /** Callbacks */
  onChipClick: (target: SwapTarget) => void
  onReplaceToggle: (playerId: string) => void
  onChangeSelect: (target: ChangeTarget) => void
  /** Slot and court for constructing targets */
  slot: number
  court: number
  /** Player ID */
  playerId: string
  /** Back-to-back runs ([3] = one run of 3, [2,2] = two runs of 2) — shown in idle mode only */
  backToBackRuns?: number[]
}

/**
 * Renders a player chip with mode-specific styling and behavior.
 *
 * Replaces the duplicated 5-level ternary chains in SummaryModal
 * for both Team A and Team B player chips.
 */
export default function PlayerChipRenderer({
  playerName,
  team,
  position,
  mode,
  done,
  pendingSwap,
  isSelected,
  isAbsent,
  isSkipped,
  hasScore,
  replaceTarget,
  changeTarget,
  onChipClick,
  onReplaceToggle,
  onChangeSelect,
  onSkipToggle,
  slot,
  court,
  playerId,
  backToBackRuns,
}: PlayerChipRendererProps & { isSkipped?: boolean; onSkipToggle?: (gameKey: string, playerId: string) => void }) {
  const target: SwapTarget = { slot, court, playerId, team, index: position }
  const gameKey = `${slot}-${court}`

  // Skip mode — amber clickable button per-game
  if (mode === 'skip') {
    return (
      <button
        onClick={() => onSkipToggle?.(gameKey, playerId)}
        className={`text-xs font-medium px-1.5 py-0.5 rounded-md border transition-colors ${
          isSkipped
            ? 'bg-amber-900/50 border-amber-500 text-amber-200 ring-1 ring-amber-500/60 line-through decoration-amber-400'
            : isAbsent
              ? 'bg-slate-800/40 border-slate-600 text-slate-400 line-through opacity-60'
              : 'bg-slate-800/60 border-slate-600 text-white hover:border-amber-400 hover:text-amber-200'
        }`}
        title={isSkipped ? 'Skipped in this game — tap to un-skip' : 'Tap to skip in this game (excludes from rating)'}
      >
        {playerName}{isSkipped ? ' ⊘' : ''}
      </button>
    )
  }

  // Replace mode — emerald clickable button
  if (mode === 'replace') {
    const isActive = replaceTarget === playerId
    return (
      <button
        onClick={() => onReplaceToggle(playerId)}
        className={`text-xs font-medium px-1.5 py-0.5 rounded-md border transition-colors ${
          isActive
            ? 'bg-emerald-900/50 border-emerald-500 text-emerald-200 ring-1 ring-emerald-500/60'
            : 'bg-slate-800/60 border-slate-600 text-slate-200 hover:border-emerald-400 hover:text-emerald-200'
        }`}
      >
        {playerName}
      </button>
    )
  }

  // Change mode — sky-blue clickable button (disabled if game has score)
  if (mode === 'change') {
    const changeTargetForChip: ChangeTarget = { slot, court, team, index: position, playerId }
    const isActive =
      changeTarget?.slot === slot &&
      changeTarget?.court === court &&
      changeTarget?.team === team &&
      changeTarget?.index === position
    return (
      <button
        onClick={() => {
          if (hasScore) return
          onChangeSelect(changeTargetForChip)
        }}
        className={`text-xs font-medium px-1.5 py-0.5 rounded-md border transition-colors ${
          isActive
            ? 'bg-sky-900/50 border-sky-500 text-sky-200 ring-1 ring-sky-500/60'
            : 'bg-slate-800/60 border-slate-600 text-slate-200 hover:border-sky-400 hover:text-sky-200'
        }`}
      >
        {playerName}
      </button>
    )
  }

  // Swap mode — no pending swap yet — indigo clickable button
  if (mode === 'swap' && !done && !pendingSwap) {
    return (
      <button
        onClick={() => onChipClick(target)}
        className={`text-xs font-medium px-1.5 py-0.5 rounded-md border transition-colors ${
          isSelected
            ? 'bg-indigo-900/50 border-indigo-500 text-indigo-200 ring-1 ring-indigo-500/60'
            : 'bg-slate-800/60 border-slate-600 text-slate-200 hover:border-indigo-400 hover:text-indigo-200'
        }`}
      >
        {playerName}
      </button>
    )
  }

  // Swap mode — pending swap exists — indigo selected / absent / plain span
  if (mode === 'swap' && !done && pendingSwap) {
    return (
      <span
        className={`text-xs font-medium px-1.5 py-0.5 rounded-md border ${
          isSelected
            ? 'bg-indigo-900/50 border-indigo-500 text-indigo-200 ring-1 ring-indigo-500/60'
            : isAbsent
              ? 'border-transparent text-slate-400 line-through'
              : 'border-transparent text-white'
        }`}
      >
        {playerName}
      </span>
    )
  }

  // Idle / default — absent / skipped / done line-through / plain white
  const showSkippedIdle = !!isSkipped
  return (
    <span
      className={`text-xs font-medium px-1.5 py-0.5 rounded-md border ${
        isAbsent
          ? 'border-transparent text-slate-400 line-through'
          : showSkippedIdle
            ? 'border-transparent text-amber-300/80 line-through decoration-amber-400/60'
            : done
              ? 'border-transparent text-slate-400 line-through'
              : 'border-transparent text-white'
      }`}
      title={showSkippedIdle ? 'Skipped in this game' : undefined}
    >
      {playerName}{showSkippedIdle ? ' ⊘' : ''}
      {backToBackRuns && backToBackRuns.length > 0 && <sup className="text-[8px] font-bold text-amber-400 shrink-0">*{backToBackRuns.join(' *')}</sup>}
    </span>
  )
}
