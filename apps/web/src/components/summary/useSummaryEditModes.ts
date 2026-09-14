// useSummaryEditModes — state machine untuk mode edit SummaryModal (swap/absent/
// skip/replace/slotSwap/teamSwap/change) + handler konfirmasi & validasi.
// Dipisah dari komponen agar render tetap tipis.
import { useMemo, useState } from 'react'
import type { DragEndEvent } from '@dnd-kit/core'
import type { Player, ScheduleSlot } from '../../types'
import { toPlayerId } from '../../types'
import type { SwapTarget, TeamSwapTarget, ChangeTarget } from '../../utils/swap'
import { detectTeamSwapConflict } from '../../utils/swap'
import type { SlotSwapTarget } from '../../utils/slotSwap'
import { detectSlotSwapConflict } from '../../utils/slotSwap'

export type ModalMode = 'idle' | 'swap' | 'absent' | 'skip' | 'replace' | 'slotSwap' | 'teamSwap' | 'change'

interface Params {
  schedule: ScheduleSlot[]
  playerMap: Map<string, Player>
  absentPlayers: string[]
  skippedPlayers: Record<string, string[]>
  /** Dipanggil saat keluar dari mode (mis. reset draft skor). */
  onExitExtra: () => void
  onSwapPlayers?: (t1: SwapTarget, t2: SwapTarget) => void
  onSetAbsent?: (next: string[]) => void
  onSetGameSkipped?: (key: string, playerIds: string[]) => void
  onSwapSlots?: (g1: SlotSwapTarget, g2: SlotSwapTarget) => void
  onSwapTeams?: (t1: TeamSwapTarget, t2: TeamSwapTarget) => void
  onChangePlayer?: (target: ChangeTarget, newName: string) => void
}

export function useSummaryEditModes({
  schedule,
  playerMap,
  absentPlayers,
  skippedPlayers,
  onExitExtra,
  onSwapPlayers,
  onSetAbsent,
  onSetGameSkipped,
  onSwapSlots,
  onSwapTeams,
  onChangePlayer,
}: Params) {
  const [mode, setMode] = useState<ModalMode>('idle')

  const [swapSelected, setSwapSelected] = useState<SwapTarget | null>(null)
  const [swapError, setSwapError] = useState<string | null>(null)
  const [pendingSwap, setPendingSwap] = useState<{ t1: SwapTarget; t2: SwapTarget } | null>(null)

  const [absentPending, setAbsentPending] = useState<Set<string>>(new Set())

  const [skipPending, setSkipPending] = useState<Map<string, Set<string>>>(new Map())

  const [replaceTarget, setReplaceTarget] = useState<string | null>(null)
  const [replaceName, setReplaceName] = useState('')

  const [pendingSlotSwap, setPendingSlotSwap] = useState<{ g1: SlotSwapTarget; g2: SlotSwapTarget } | null>(null)
  const [slotSwapError, setSlotSwapError] = useState<string | null>(null)

  const [teamSwapSelected, setTeamSwapSelected] = useState<TeamSwapTarget | null>(null)
  const [pendingTeamSwap, setPendingTeamSwap] = useState<{ t1: TeamSwapTarget; t2: TeamSwapTarget } | null>(null)
  const [teamSwapError, setTeamSwapError] = useState<string | null>(null)

  const [changeTarget, setChangeTarget] = useState<ChangeTarget | null>(null)
  const [changeName, setChangeName] = useState('')
  const [changeError, setChangeError] = useState<string | null>(null)
  const [pendingChange, setPendingChange] = useState<{ target: ChangeTarget; newName: string; b2b: boolean } | null>(null)

  const [actionsOpen, setActionsOpen] = useState(false)

  // Exit current mode and reset associated state
  function exitCurrentMode() {
    switch (mode) {
      case 'swap':
        setSwapSelected(null)
        setSwapError(null)
        setPendingSwap(null)
        break
      case 'absent':
        setAbsentPending(new Set())
        break
      case 'skip':
        setSkipPending(new Map())
        break
      case 'replace':
        setReplaceTarget(null)
        setReplaceName('')
        break
      case 'slotSwap':
        setPendingSlotSwap(null)
        setSlotSwapError(null)
        break
      case 'teamSwap':
        setTeamSwapSelected(null)
        setPendingTeamSwap(null)
        setTeamSwapError(null)
        break
      case 'change':
        setChangeTarget(null)
        setChangeName('')
        setChangeError(null)
        setPendingChange(null)
        break
    }
    setMode('idle')
    // Reset score-related state
    onExitExtra()
  }

  function enterSwapMode() {
    exitCurrentMode()
    setMode('swap')
  }

  function enterAbsentMode() {
    exitCurrentMode()
    setAbsentPending(new Set(absentPlayers))
    setMode('absent')
  }

  function enterSkipMode() {
    exitCurrentMode()
    const m = new Map<string, Set<string>>()
    for (const [k, v] of Object.entries(skippedPlayers)) m.set(k, new Set(v))
    setSkipPending(m)
    setMode('skip')
  }

  function toggleSkipForGame(gameKey: string, playerId: string) {
    setSkipPending(prev => {
      const next = new Map(prev)
      const cur = new Set(next.get(gameKey) ?? [])
      if (cur.has(playerId)) cur.delete(playerId)
      else cur.add(playerId)
      if (cur.size === 0) next.delete(gameKey)
      else next.set(gameKey, cur)
      return next
    })
  }

  function enterReplaceMode() {
    exitCurrentMode()
    setMode('replace')
  }

  function enterSlotSwapMode() {
    exitCurrentMode()
    setActionsOpen(false)
    setMode('slotSwap')
  }

  function enterTeamSwapMode() {
    exitCurrentMode()
    setActionsOpen(false)
    setMode('teamSwap')
  }

  function enterChangeMode() {
    exitCurrentMode()
    setActionsOpen(false)
    setMode('change')
  }

  function handleDragEnd(event: DragEndEvent) {
    const { active, over } = event
    if (!over || active.id === over.id) return
    const parseId = (id: string | number) => {
      const [slot, court] = String(id).split('-').map(Number)
      return { slot, court }
    }
    const g1 = parseId(active.id)
    const g2 = parseId(over.id)
    const conflictId = detectSlotSwapConflict(schedule, g1, g2)
    if (conflictId) {
      setSlotSwapError(`Can't switch — ${playerMap.get(conflictId)?.name ?? conflictId} already plays in that slot`)
      return
    }
    setSlotSwapError(null)
    setPendingSlotSwap({ g1, g2 })
  }

  function handleTeamClick(target: TeamSwapTarget) {
    if (mode !== 'teamSwap') return
    if (
      teamSwapSelected &&
      teamSwapSelected.slot === target.slot &&
      teamSwapSelected.court === target.court &&
      teamSwapSelected.team === target.team
    ) {
      setTeamSwapSelected(null)
      setTeamSwapError(null)
      return
    }
    if (!teamSwapSelected) {
      setTeamSwapSelected(target)
      setTeamSwapError(null)
      return
    }
    const conflictId = detectTeamSwapConflict(schedule, teamSwapSelected, target)
    if (conflictId) {
      setTeamSwapError(`Can't swap — ${playerMap.get(conflictId)?.name ?? conflictId} already plays in that game`)
      setTeamSwapSelected(null)
      return
    }
    setTeamSwapError(null)
    setPendingTeamSwap({ t1: teamSwapSelected, t2: target })
    setTeamSwapSelected(null)
  }

  function handleChipClick(target: SwapTarget) {
    if (mode !== 'swap') return
    if (!swapSelected) {
      setSwapSelected(target)
      setSwapError(null)
      return
    }
    // Tap same chip again → deselect
    if (
      swapSelected.slot === target.slot &&
      swapSelected.court === target.court &&
      swapSelected.playerId === target.playerId
    ) {
      setSwapSelected(null)
      setSwapError(null)
      return
    }
    // Same player → error
    if (swapSelected.playerId === target.playerId) {
      setSwapError('Cannot swap a player with themselves')
      setSwapSelected(null)
      return
    }
    // Different games: check no player already plays in the other game
    const isSameGame = swapSelected.slot === target.slot && swapSelected.court === target.court
    if (!isSameGame) {
      const targetGame = schedule.find(g => g.slot === target.slot && g.court === target.court)
      const selectedGame = schedule.find(g => g.slot === swapSelected.slot && g.court === swapSelected.court)
      const targetGamePlayers = targetGame ? [...targetGame.teamA, ...targetGame.teamB] : []
      const selectedGamePlayers = selectedGame ? [...selectedGame.teamA, ...selectedGame.teamB] : []
      if (targetGamePlayers.includes(toPlayerId(swapSelected.playerId)) || selectedGamePlayers.includes(toPlayerId(target.playerId))) {
        setSwapError('One player already plays in the other\'s game')
        setSwapSelected(null)
        return
      }
    }
    setSwapError(null)
    setPendingSwap({ t1: swapSelected, t2: target })
    setSwapSelected(null)
  }

  // Toggle replace target selection
  function handleReplaceToggle(playerId: string) {
    if (replaceTarget === playerId) {
      setReplaceTarget(null)
      setReplaceName('')
    } else {
      setReplaceTarget(playerId)
      setReplaceName('')
    }
  }

  // Select change target
  function handleChangeSelect(target: ChangeTarget) {
    setChangeTarget(target)
    setChangeName('')
    setChangeError(null)
  }

  // In absent mode, preview pending selections; otherwise use saved state.
  // useMemo → identitas stabil supaya memo di StandingsTab tidak invalid tiap render.
  const effectiveAbsent = useMemo(
    () => (mode === 'absent' ? absentPending : new Set(absentPlayers)),
    [mode, absentPending, absentPlayers],
  )

  // True when pending state differs from saved state
  const absentChanged = mode === 'absent' && (() => {
    const saved = new Set(absentPlayers)
    if (absentPending.size !== saved.size) return true
    for (const id of absentPending) if (!saved.has(id)) return true
    return false
  })()

  // Skip: effective per-game map + changed detection (identitas stabil via useMemo).
  const effectiveSkipped: Record<string, Set<string>> = useMemo(() => {
    if (mode === 'skip') {
      const out: Record<string, Set<string>> = {}
      for (const [k, v] of skipPending) out[k] = new Set(v)
      return out
    }
    const out: Record<string, Set<string>> = {}
    for (const [k, v] of Object.entries(skippedPlayers)) out[k] = new Set(v)
    return out
  }, [mode, skipPending, skippedPlayers])

  const skipChanged = mode === 'skip' && (() => {
    const allKeys = new Set([...Object.keys(skippedPlayers), ...skipPending.keys()])
    for (const k of allKeys) {
      const a = new Set(skippedPlayers[k] ?? [])
      const b = skipPending.get(k) ?? new Set()
      if (a.size !== b.size) return true
      for (const id of a) if (!b.has(id)) return true
    }
    return false
  })()

  const flatSkippedCount = Object.values(effectiveSkipped).reduce((n, s) => n + s.size, 0)

  // ConfirmBars callbacks
  function handleCancelSwap() { setPendingSwap(null) }
  function handleConfirmSwap() { if (pendingSwap) { onSwapPlayers?.(pendingSwap.t1, pendingSwap.t2); exitCurrentMode() } }
  function handleCancelSlotSwap() { setPendingSlotSwap(null) }
  function handleConfirmSlotSwap() { if (pendingSlotSwap) { onSwapSlots?.(pendingSlotSwap.g1, pendingSlotSwap.g2); exitCurrentMode() } }
  function handleCancelTeamSwap() { exitCurrentMode() }
  function handleConfirmTeamSwap() { if (pendingTeamSwap) { onSwapTeams?.(pendingTeamSwap.t1, pendingTeamSwap.t2); exitCurrentMode() } }
  function handleCancelChange() { setPendingChange(null) }
  function handleConfirmChange() { if (pendingChange) { onChangePlayer?.(pendingChange.target, pendingChange.newName); exitCurrentMode() } }
  function handleConfirmAbsent() {
    const ids = [...absentPending]
    onSetAbsent?.(ids)
    exitCurrentMode()
  }

  function handleConfirmSkip() {
    // Send per-game PATCH sequentially (row-level OCC, low contention)
    for (const [key, set] of skipPending) {
      onSetGameSkipped?.(key, [...set])
    }
    // Also clear games that were skipped before but now empty
    for (const k of Object.keys(skippedPlayers)) {
      if (!skipPending.has(k)) onSetGameSkipped?.(k, [])
    }
    exitCurrentMode()
  }

  return {
    mode,
    setMode,
    actionsOpen,
    setActionsOpen,
    swapSelected,
    swapError,
    pendingSwap,
    absentPending,
    setAbsentPending,
    skipPending,
    replaceTarget,
    replaceName,
    setReplaceName,
    pendingSlotSwap,
    slotSwapError,
    teamSwapSelected,
    pendingTeamSwap,
    teamSwapError,
    changeTarget,
    changeName,
    setChangeName,
    changeError,
    setChangeError,
    pendingChange,
    setPendingChange,
    exitCurrentMode,
    enterSwapMode,
    enterAbsentMode,
    enterSkipMode,
    enterReplaceMode,
    enterSlotSwapMode,
    enterTeamSwapMode,
    enterChangeMode,
    handleChipClick,
    handleTeamClick,
    handleReplaceToggle,
    handleChangeSelect,
    handleDragEnd,
    toggleSkipForGame,
    handleCancelSwap,
    handleConfirmSwap,
    handleCancelSlotSwap,
    handleConfirmSlotSwap,
    handleCancelTeamSwap,
    handleConfirmTeamSwap,
    handleCancelChange,
    handleConfirmChange,
    handleConfirmAbsent,
    handleConfirmSkip,
    effectiveAbsent,
    absentChanged,
    effectiveSkipped,
    skipChanged,
    flatSkippedCount,
  }
}

export type SummaryEditModes = ReturnType<typeof useSummaryEditModes>
