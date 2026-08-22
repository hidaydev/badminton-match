import { useState } from 'react'
import {
  PointerSensor,
  TouchSensor,
  useSensor,
  useSensors,
  type DragEndEvent,
} from '@dnd-kit/core'
import type { GeneratorResult } from '../generator'
import type { Player, GameScore, CourtTime } from '../types'
import { toPlayerId } from '../types'
import { formatMergedCourtTimes } from '../utils/time'
import type { SwapTarget, TeamSwapTarget, ChangeTarget } from '../utils/swap'
import { detectTeamSwapConflict, validateChangeName } from '../utils/swap'
import type { SlotSwapTarget } from '../utils/slotSwap'
import { detectSlotSwapConflict } from '../utils/slotSwap'
import ConfirmBars from './summary/ConfirmBars'
import ActionsMenu from './summary/ActionsMenu'
import PlayerStatsPanel from './summary/PlayerStatsPanel'
import ScheduleGrid from './summary/ScheduleGrid'
import StandingsTab from './summary/StandingsTab'
import { validateScore } from '../utils/scoreValidation'

/** Read-only data props for SummaryModal */
interface SummaryModalBaseProps {
  result: GeneratorResult
  playerMap: Map<string, Player>
  slotsPerCourt: number[]
  courtNames: string[]
  playedGames: string[]
  gameScores: Record<string, GameScore>
  title: string
  date: string
  sessionStart: string
  slotMinutes: number
  courtTimes: CourtTime[]
  standalone?: boolean
  locked?: boolean
  absentPlayers?: string[]
}

/** Edit callback props for SummaryModal (all optional for read-only views) */
interface SummaryModalEditProps {
  onTogglePlayedGame?: (key: string) => void
  onSetGameScore?: (key: string, a: number, b: number) => void
  onSwapPlayers?: (t1: SwapTarget, t2: SwapTarget) => void
  onSetAbsent?: (nextAbsent: string[]) => void
  onReplacePlayer?: (playerId: string, newName: string) => void
  onSwapSlots?: (g1: SlotSwapTarget, g2: SlotSwapTarget) => void
  onSwapTeams?: (t1: TeamSwapTarget, t2: TeamSwapTarget) => void
  onChangePlayer?: (target: ChangeTarget, newName: string) => void
  onRefetch?: () => void
  isRefetching?: boolean
  onDelete?: () => void
  deleteLoading?: boolean
  onClose?: () => void
  saving?: boolean
}

type SummaryModalProps = SummaryModalBaseProps & SummaryModalEditProps

export default function SummaryModal({
  result,
  playerMap,
  slotsPerCourt,
  courtNames,
  playedGames: playedArr,
  gameScores,
  onTogglePlayedGame,
  onSetGameScore,
  onClose,
  title,
  date,
  sessionStart,
  slotMinutes,
  courtTimes,
  saving = false,
  standalone = false,
  onSwapPlayers,
  absentPlayers = [],
  onSetAbsent,
  onReplacePlayer,
  onSwapSlots,
  onSwapTeams,
  onChangePlayer,
  onRefetch,
  isRefetching = false,
  onDelete,
  deleteLoading = false,
  locked = false,
}: SummaryModalProps) {
  const courts = slotsPerCourt.length
  const played = new Set(playedArr)

  const [activeTab, setActiveTab] = useState<'schedule' | 'standings'>('schedule')
  const [expandedScore, setExpandedScore] = useState<string | null>(null)
  const [scoreError, setScoreError] = useState<string | null>(null)
  const [draftScores, setDraftScores] = useState<Record<string, { a: string; b: string }>>({})

  // Discriminated union for modal modes - replaces 6 separate boolean states
  type ModalMode = 'idle' | 'swap' | 'absent' | 'replace' | 'slotSwap' | 'teamSwap' | 'change'
  const [mode, setMode] = useState<ModalMode>('idle')

  const [swapSelected, setSwapSelected] = useState<SwapTarget | null>(null)
  const [swapError, setSwapError] = useState<string | null>(null)
  const [pendingSwap, setPendingSwap] = useState<{ t1: SwapTarget; t2: SwapTarget } | null>(null)

  const [absentPending, setAbsentPending] = useState<Set<string>>(new Set())
  // P2 — konfirmasi void saat mark absent (game memuat pemain absent).
  const [absentConfirm, setAbsentConfirm] = useState<{ ids: string[]; gameCount: number } | null>(null)

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
  const [deleteConfirm, setDeleteConfirm] = useState(false)

  const sensors = useSensors(
    useSensor(PointerSensor),
    useSensor(TouchSensor, { activationConstraint: { delay: 200, tolerance: 5 } }),
  )

  function handleDragEnd(event: DragEndEvent) {
    const { active, over } = event
    if (!over || active.id === over.id) return
    const parseId = (id: string | number) => {
      const [slot, court] = String(id).split('-').map(Number)
      return { slot, court }
    }
    const g1 = parseId(active.id)
    const g2 = parseId(over.id)
    const conflictId = detectSlotSwapConflict(result.schedule, g1, g2)
    if (conflictId) {
      setSlotSwapError(`Can't switch — ${playerMap.get(conflictId)?.name ?? conflictId} already plays in that slot`)
      return
    }
    setSlotSwapError(null)
    setPendingSlotSwap({ g1, g2 })
  }

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
    setExpandedScore(null)
    setDraftScores({})
    setScoreError(null)
    setAbsentConfirm(null)
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
    const conflictId = detectTeamSwapConflict(result.schedule, teamSwapSelected, target)
    if (conflictId) {
      setTeamSwapError(`Can't swap — ${playerMap.get(conflictId)?.name ?? conflictId} already plays in that game`)
      setTeamSwapSelected(null)
      return
    }
    setTeamSwapError(null)
    setPendingTeamSwap({ t1: teamSwapSelected, t2: target })
    setTeamSwapSelected(null)
  }

  // In absent mode, preview pending selections; otherwise use saved state
  const effectiveAbsent = mode === 'absent' ? absentPending : new Set(absentPlayers)

  // True when pending state differs from saved state
  const absentChanged = mode === 'absent' && (() => {
    const saved = new Set(absentPlayers)
    if (absentPending.size !== saved.size) return true
    for (const id of absentPending) if (!saved.has(id)) return true
    return false
  })()

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
      const targetGame = result.schedule.find(g => g.slot === target.slot && g.court === target.court)
      const selectedGame = result.schedule.find(g => g.slot === swapSelected.slot && g.court === swapSelected.court)
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

  const bySlot = new Map<number, (typeof result.schedule)>()
  for (const game of result.schedule) {
    const list = bySlot.get(game.slot) ?? []
    list.push(game)
    bySlot.set(game.slot, list)
  }

  const slotPlayerSet = new Map<number, Set<string>>()
  for (const [t, games] of bySlot) {
    const set = new Set<string>()
    for (const g of games) { g.teamA.forEach((id) => set.add(id)); g.teamB.forEach((id) => set.add(id)) }
    slotPlayerSet.set(t, set)
  }
  const courtLabel = (i: number) =>
    courtNames[i] || (courts <= 26 ? String.fromCharCode(65 + i) : String(i + 1))

  const totalGames = result.schedule.length
  const playedCount = played.size

  function trySaveScore(key: string): boolean {
    const draft = draftScores[key]
    if (!draft) return false
    const a = parseInt(draft.a, 10)
    const b = parseInt(draft.b, 10)
    if (isNaN(a) || isNaN(b)) return false
    if (a < 0 || a > 99 || b < 0 || b > 99) return false
    const err = validateScore(a, b)
    if (err) { setScoreError(err); return false }
    setScoreError(null)
    onSetGameScore?.(key, a, b)
    return true
  }

  function handleScoreSave(key: string) {
    if (trySaveScore(key)) setExpandedScore(null)
  }

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
    // P2 — prompt sebelum void: hitung game yang memuat pemain yang baru
    // di-mark absent (ABSENT_TBD_PLAYERS_DESIGN.md §4.4).
    const ids = [...absentPending]
    const gameCount = result.schedule.filter(
      (slot) => slot.teamA.some((id) => ids.includes(id)) || slot.teamB.some((id) => ids.includes(id)),
    ).length
    if (gameCount > 0 && !locked) {
      setAbsentConfirm({ ids, gameCount })
      exitCurrentMode()
      return
    }
    // No games affected — just set absent directly
    onSetAbsent?.(ids)
    exitCurrentMode()
  }

  function handleConfirmVoid() {
    if (!absentConfirm) return
    const ids = absentConfirm.ids

    // AUTO-UNCHECK: uncheck all games involving absent players
    const affectedKeys = new Set(
      result.schedule
        .filter((slot) => slot.teamA.some((id) => ids.includes(id)) || slot.teamB.some((id) => ids.includes(id)))
        .map((slot) => `${slot.slot}-${slot.court}`)
    )
    if (affectedKeys.size > 0) {
      // Remove affected games from playedGames and clear their scores
      const newPlayed = result.playedGames.filter((k) => !affectedKeys.has(k))
      const newScores = { ...result.gameScores }
      affectedKeys.forEach((k) => delete newScores[k])
      setResult({ ...result, playedGames: newPlayed, gameScores: newScores })
    }

    onSetAbsent?.(ids)
    setAbsentConfirm(null)
  }

  return (
    <div className={standalone ? 'flex-1 flex flex-col bg-ground overflow-hidden' : 'fixed inset-0 z-50 bg-ground flex flex-col overflow-hidden'} role="dialog" aria-modal={!standalone} aria-label="Session summary">
      {/* Toolbar */}
      <div className="flex items-center justify-between px-5 py-3 border-b border-slate-800 shrink-0">
        <div className="flex items-center gap-3">
          <div className="flex gap-1">
            <button
              onClick={() => { setActiveTab('schedule'); exitCurrentMode() }}
              className={`text-xs font-semibold px-3 py-1.5 rounded-lg transition-colors ${activeTab === 'schedule' ? 'bg-indigo-900/60 border border-indigo-700 text-indigo-300' : 'text-slate-400 hover:text-slate-200'}`}
            >
              Schedule
            </button>
            <button
              onClick={() => { setActiveTab('standings'); exitCurrentMode() }}
              className={`text-xs font-semibold px-3 py-1.5 rounded-lg transition-colors ${activeTab === 'standings' ? 'bg-indigo-900/60 border border-indigo-700 text-indigo-300' : 'text-slate-400 hover:text-slate-200'}`}
            >
              Leaderboard
            </button>
          </div>
          {playedCount > 0 && (
            <span className="text-xs text-slate-400">
              {playedCount}/{totalGames} played
            </span>
          )}
        </div>
        <div className="flex items-center gap-2">
          {locked && (
            <span className="text-xs font-semibold px-3 py-1.5 rounded-lg bg-amber-900/40 border border-amber-700 text-amber-400">
              🔒<span className="hidden sm:inline"> Locked</span>
            </span>
          )}
          {!locked && activeTab === 'schedule' && (onSwapPlayers || onSetAbsent || onReplacePlayer || onSwapSlots || onSwapTeams) && (
            mode !== 'idle' ? (
              <button
                onClick={() => { exitCurrentMode(); setActionsOpen(false) }}
                className="text-xs font-semibold px-3 py-1.5 rounded-lg bg-slate-800 border border-slate-600 text-slate-300 hover:text-white transition-colors"
              >
                ✕<span className="hidden sm:inline"> Cancel</span>
              </button>
            ) : (
              <ActionsMenu
                actionsOpen={actionsOpen}
                onToggle={() => setActionsOpen((v) => !v)}
                onClose={() => setActionsOpen(false)}
                onEnterSwapMode={() => { setActionsOpen(false); enterSwapMode() }}
                onEnterTeamSwapMode={() => { setActionsOpen(false); enterTeamSwapMode() }}
                onEnterReplaceMode={() => { setActionsOpen(false); enterReplaceMode() }}
                onEnterChangeMode={() => { setActionsOpen(false); enterChangeMode() }}
                onEnterSlotSwapMode={() => { setActionsOpen(false); enterSlotSwapMode() }}
                onEnterAbsentMode={() => { setActionsOpen(false); enterAbsentMode() }}
                hasSwapPlayers={!!onSwapPlayers}
                hasSwapTeams={!!onSwapTeams}
                hasReplacePlayer={!!onReplacePlayer}
                hasChangePlayer={!!onChangePlayer}
                hasSwapSlots={!!onSwapSlots}
                hasSetAbsent={!!onSetAbsent}
              />
            )
          )}
          {/* Delete button */}
          {onDelete && !deleteConfirm && (
            <button
              onClick={() => setDeleteConfirm(true)}
              className="text-slate-400 hover:text-red-400 px-2 py-1.5 rounded-lg hover:bg-red-950/30 transition-colors text-sm"
              title="Delete session"
            >
              <svg xmlns="http://www.w3.org/2000/svg" width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
                <path d="M3 6h18"/><path d="M19 6v14c0 1-1 2-2 2H7c-1 0-2-1-2-2V6"/><path d="M8 6V4c0-1 1-2 2-2h4c1 0 2 1 2 2v2"/>
              </svg>
            </button>
          )}
          {onDelete && deleteConfirm && (
            <button
              onClick={() => { onDelete(); setDeleteConfirm(false) }}
              disabled={deleteLoading}
              className="text-xs font-bold px-3 py-1.5 rounded-lg bg-red-600 hover:bg-red-500 text-white transition-colors disabled:opacity-50 flex items-center gap-1.5"
            >
              {deleteLoading && <svg className="animate-spin w-3 h-3 shrink-0" viewBox="0 0 24 24" fill="none"><circle className="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" strokeWidth="4" /><path className="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4z" /></svg>}
              {deleteLoading ? 'Deleting…' : 'Confirm delete'}
            </button>
          )}
          {deleteConfirm && (
            <button
              onClick={() => setDeleteConfirm(false)}
              className="text-xs text-slate-400 hover:text-slate-200 px-2 py-1.5 rounded-lg border border-slate-700 bg-slate-800/60 transition-colors"
            >
              ✕
            </button>
          )}
          {/* Close button — only when onClose is provided */}
          {onClose && !deleteConfirm && (
            <button
              onClick={onClose}
              className="text-slate-400 hover:text-white px-3 py-1.5 rounded-lg hover:bg-slate-800 transition-colors text-sm"
            >
              Close
            </button>
          )}
        </div>
      </div>

      {/* Session header */}
      {(title || date) && (
        <div className="px-5 py-3 border-b border-slate-800 shrink-0 flex items-center gap-2">
          <div className="flex-1 min-w-0">
            {title && <p className="text-white font-bold text-[1rem] leading-tight">{title}</p>}
            {date && (
              <p className="text-slate-400 text-xs mt-0.5">
                {new Date(date + 'T00:00:00').toLocaleDateString('en-GB', {
                  weekday: 'long',
                  day: 'numeric',
                  month: 'long',
                  year: 'numeric',
                })}
                {courtTimes.length > 0 && (
                  <span className="text-slate-400"> · {formatMergedCourtTimes(courtTimes)}</span>
                )}
              </p>
            )}
          </div>
          {onRefetch && (
            <button
              onClick={onRefetch}
              disabled={isRefetching}
              className="p-1.5 rounded-lg text-slate-400 hover:text-white hover:bg-slate-800 active:scale-90 transition-all disabled:opacity-40 shrink-0"
              aria-label="Reload session"
            >
              <svg
                xmlns="http://www.w3.org/2000/svg"
                width="16"
                height="16"
                viewBox="0 0 24 24"
                fill="none"
                stroke="currentColor"
                strokeWidth="2.5"
                strokeLinecap="round"
                strokeLinejoin="round"
                className={isRefetching ? 'animate-spin' : ''}
              >
                <path d="M21 12a9 9 0 1 1-9-9c2.52 0 4.93 1 6.74 2.74L21 8"/>
                <path d="M21 3v5h-5"/>
              </svg>
            </button>
          )}
        </div>
      )}

      {/* Content */}
      <div className={`flex-1 overflow-auto px-4 py-4 max-w-xl mx-auto w-full ${pendingSwap || absentChanged || pendingTeamSwap || pendingChange ? 'pb-24' : pendingSlotSwap ? 'pb-36' : ''}`}>
        {mode === 'swap' && !pendingSwap && (
          <div className="mb-3 rounded-lg bg-indigo-950/50 border border-indigo-800/40 px-3 py-2 flex flex-col gap-1">
            <span className="text-xs text-indigo-300 font-medium">
              {swapSelected
                ? '1 of 2 selected — tap another player to swap'
                : 'Select two players to swap'}
            </span>
            {swapError && (
              <span className="text-[11px] text-red-400">{swapError}</span>
            )}
          </div>
        )}
        {mode === 'absent' && (
          <div className="mb-3 rounded-lg bg-red-950/30 border border-red-900/40 px-3 py-2 flex flex-col gap-2">
            <span className="text-xs text-red-300 font-medium">
              {absentPending.size > 0
                ? `${absentPending.size} player${absentPending.size === 1 ? '' : 's'} marked absent — tap to toggle`
                : 'Tap players to mark absent'}
            </span>
            <div className="flex flex-wrap gap-1.5">
              {[...playerMap.values()].map((p) => {
                const isSelected = absentPending.has(p.id)
                return (
                  <button
                    key={p.id}
                    onClick={() => {
                      setAbsentPending((prev) => {
                        const next = new Set(prev)
                        if (next.has(p.id)) next.delete(p.id)
                        else next.add(p.id)
                        return next
                      })
                    }}
                    className={`text-xs font-medium px-2 py-0.5 rounded-md border transition-colors ${
                      isSelected
                        ? 'bg-red-900/60 border-red-700 text-red-200'
                        : 'bg-slate-800/60 border-slate-600 text-slate-300 hover:border-red-700 hover:text-red-300'
                    }`}
                  >
                    {p.name}{isSelected ? ' ✓' : ''}
                  </button>
                )
              })}
            </div>
          </div>
        )}
        {mode === 'replace' && (
          <div className="mb-3 rounded-lg bg-emerald-950/30 border border-emerald-900/40 px-3 py-2 flex flex-col gap-2">
            {replaceTarget === null ? (
              <span className="text-xs text-emerald-300 font-medium">Tap a player to replace</span>
            ) : (
              <>
                <span className="text-xs text-emerald-300 font-medium">
                  Replace <strong>{playerMap.get(replaceTarget)?.name}</strong> with:
                </span>
                <div className="flex gap-2 items-center">
                  <input
                    type="text"
                    value={replaceName}
                    onChange={(e) => setReplaceName(e.target.value)}
                    onKeyDown={async (e) => {
                      if (e.key === 'Enter' && replaceName.trim()) {
                        await onReplacePlayer?.(replaceTarget, replaceName.trim())
                        exitCurrentMode()
                      }
                    }}
                    placeholder="New name…"
                    autoFocus
                    className="flex-1 bg-slate-900 border border-emerald-800 rounded-lg px-3 py-1.5 text-xs text-white placeholder:text-slate-400 focus:outline-none focus:border-emerald-500 focus-visible:ring-2 focus-visible:ring-emerald-500/50"
                  />
                  <button
                    onClick={async () => {
                      if (!replaceName.trim()) return
                      await onReplacePlayer?.(replaceTarget, replaceName.trim())
                      exitCurrentMode()
                    }}
                    disabled={!replaceName.trim() || saving}
                    className="text-xs font-bold px-3 py-1.5 rounded-lg bg-emerald-700 hover:bg-emerald-600 text-white transition-colors disabled:opacity-50 disabled:cursor-not-allowed shrink-0 flex items-center gap-1.5"
                  >
                    {saving && <svg className="animate-spin w-3 h-3 shrink-0" viewBox="0 0 24 24" fill="none"><circle className="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" strokeWidth="4" /><path className="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4z" /></svg>}
                    {saving ? 'Saving…' : '✓ Save'}
                  </button>
                </div>
              </>
            )}
          </div>
        )}
        {mode === 'slotSwap' && (
          <div className="mb-3 rounded-lg bg-orange-950/30 border border-orange-900/40 px-3 py-2">
            {slotSwapError ? (
              <span className="text-xs text-red-400">{slotSwapError}</span>
            ) : (
              <span className="text-xs text-orange-300 font-medium">↕ Drag ⠿ to switch a game's slot</span>
            )}
          </div>
        )}
        {mode === 'teamSwap' && (
          <div className="mb-3 rounded-lg bg-violet-950/30 border border-violet-900/40 px-3 py-2">
            {teamSwapError ? (
              <span className="text-xs text-red-400">{teamSwapError}</span>
            ) : (
              <span className="text-xs text-violet-300 font-medium">⇄ Tap a team to select, then tap another team to swap</span>
            )}
          </div>
        )}
        {mode === 'change' && (
          <div className="mb-3 rounded-lg bg-sky-950/30 border border-sky-900/40 px-3 py-2 flex flex-col gap-2">
            {changeTarget === null ? (
              <span className="text-xs text-sky-300 font-medium">Tap a player to change them out</span>
            ) : (
              <>
                <span className="text-xs text-sky-300 font-medium">
                  Change <strong>{playerMap.get(changeTarget.playerId)?.name ?? '?'}</strong> (Slot {changeTarget.slot + 1}, {courtLabel(changeTarget.court)}) to:
                </span>
                <div className="flex gap-2 items-center">
                  <input
                    type="text"
                    value={changeName}
                    onChange={(e) => { setChangeName(e.target.value); setChangeError(null) }}
                    onKeyDown={(e) => {
                      if (e.key === 'Enter' && changeName.trim()) {
                        const name = changeName.trim()
                        const validation = validateChangeName(changeTarget, name, result.schedule, playerMap)
                        if (validation.error) { setChangeError(validation.error); return }
                        setPendingChange({ target: changeTarget, newName: name, b2b: validation.b2b })
                      }
                    }}
                    placeholder="New name…"
                    autoFocus
                    className="flex-1 bg-slate-900 border border-sky-800 rounded-lg px-3 py-1.5 text-xs text-white placeholder:text-slate-400 focus:outline-none focus:border-sky-500 focus-visible:ring-2 focus-visible:ring-sky-500/50"
                  />
                  <button
                    onClick={() => {
                      if (!changeName.trim()) return
                      const name = changeName.trim()
                      const validation = validateChangeName(changeTarget, name, result.schedule, playerMap)
                      if (validation.error) { setChangeError(validation.error); return }
                      setPendingChange({ target: changeTarget, newName: name, b2b: validation.b2b })
                    }}
                    disabled={!changeName.trim() || saving}
                    className="text-xs font-bold px-3 py-1.5 rounded-lg bg-sky-700 hover:bg-sky-600 text-white transition-colors disabled:opacity-50 disabled:cursor-not-allowed shrink-0"
                  >
                    Next
                  </button>
                </div>
                {changeError && (
                  <span className="text-[11px] text-red-400">{changeError}</span>
                )}
              </>
            )}
          </div>
        )}
        {activeTab === 'standings' ? (
          <StandingsTab
            players={[...playerMap.values()]}
            schedule={result.schedule}
            gameScores={gameScores}
            absentPlayerIds={[...effectiveAbsent]}
          />
        ) : (
          <ScheduleGrid
            result={result}
            slotsPerCourt={slotsPerCourt}
            courtNames={courtNames}
            sessionStart={sessionStart}
            slotMinutes={slotMinutes}
            mode={mode}
            locked={locked}
            saving={saving}
            playerMap={playerMap}
            playedGames={playedArr}
            gameScores={gameScores}
            effectiveAbsent={effectiveAbsent}
            expandedScore={expandedScore}
            draftScores={draftScores}
            scoreError={scoreError}
            swapSelected={swapSelected}
            pendingSwap={pendingSwap}
            teamSwapSelected={teamSwapSelected}
            pendingTeamSwap={pendingTeamSwap}
            replaceTarget={replaceTarget}
            changeTarget={changeTarget}
            sensors={sensors}
            handleChipClick={handleChipClick}
            handleTeamClick={handleTeamClick}
            handleReplaceToggle={handleReplaceToggle}
            handleChangeSelect={handleChangeSelect}
            handleDragEnd={handleDragEnd}
            handleScoreSave={handleScoreSave}
            onTogglePlayedGame={onTogglePlayedGame}
            setExpandedScore={setExpandedScore}
            setScoreError={setScoreError}
            setDraftScores={setDraftScores}
          />
        )}

        {/* Player Stats — shown below schedule */}
        {activeTab === 'schedule' && (
          <PlayerStatsPanel
            schedule={result.schedule}
            playerMap={playerMap}
            absentPlayers={absentPlayers}
            standalone={standalone}
          />
        )}
      </div>

      <ConfirmBars
        pendingSwap={pendingSwap}
        onCancelSwap={handleCancelSwap}
        onConfirmSwap={handleConfirmSwap}
        absentChanged={absentChanged}
        absentPending={absentPending}
        onCancelAbsent={exitCurrentMode}
        onConfirmAbsent={handleConfirmAbsent}
        pendingSlotSwap={pendingSlotSwap}
        onCancelSlotSwap={handleCancelSlotSwap}
        onConfirmSlotSwap={handleConfirmSlotSwap}
        pendingTeamSwap={pendingTeamSwap}
        onCancelTeamSwap={handleCancelTeamSwap}
        onConfirmTeamSwap={handleConfirmTeamSwap}
        pendingChange={pendingChange}
        onCancelChange={handleCancelChange}
        onConfirmChange={handleConfirmChange}
        playerMap={playerMap}
        schedule={result.schedule}
        saving={saving}
        courtLabel={courtLabel}
      />

      {/* P2 — konfirmasi VOID saat mark absent */}
      {absentConfirm && (
        <div className="fixed inset-0 z-60 flex items-end justify-center bg-black/50" onClick={() => setAbsentConfirm(null)}>
          <div
            className="bg-slate-900 border border-slate-700 rounded-t-2xl w-full max-w-lg p-4 pb-6"
            onClick={(e) => e.stopPropagation()}
          >
            <h3 className="text-sm font-bold text-slate-100 mb-1">
              {absentConfirm.ids.length} player{absentConfirm.ids.length === 1 ? '' : 's'} marked absent
            </h3>
            <p className="text-xs text-slate-400 mb-3">
              <span className="text-slate-300">{absentConfirm.gameCount} game{absentConfirm.gameCount === 1 ? '' : 's'}</span>{' '}
              involving{' '}
              <span className="text-slate-300">
                {absentConfirm.ids.map((id) => playerMap.get(id)?.name ?? id).join(', ')}
              </span>{' '}
              will not count (void). Replace the player in those games first, or leave them as-is.
            </p>
            <div className="flex flex-col gap-2">
              <button
                onClick={() => { setAbsentConfirm(null); enterChangeMode() }}
                className="w-full py-2.5 rounded-lg bg-indigo-600 text-white text-sm font-bold"
              >
                Replace in games
              </button>
              <button
                onClick={handleConfirmVoid}
                className="w-full py-2.5 rounded-lg bg-red-900/50 border border-red-700 text-red-200 text-sm font-bold"
              >
                Continue — void those games
              </button>
            </div>
          </div>
        </div>
      )}
    </div>
  )
}
