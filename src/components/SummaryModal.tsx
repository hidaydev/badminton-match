import { useState } from 'react'
import {
  DndContext,
  useDraggable,
  useDroppable,
  PointerSensor,
  TouchSensor,
  useSensor,
  useSensors,
  type DragEndEvent,
} from '@dnd-kit/core'
import { CSS } from '@dnd-kit/utilities'
import type { GeneratorResult } from '../generator'
import type { Player, GameScore, CourtTime } from '../store'
import { timeToMinutes, minutesToTime } from '../store'
import { computeStandings } from '../utils/standings'
import type { SwapTarget, TeamSwapTarget, ChangeTarget } from '../utils/swap'
import { detectTeamSwapConflict, detectChangeConflict } from '../utils/swap'
import type { SlotSwapTarget } from '../utils/slotSwap'
import { detectSlotSwapConflict } from '../utils/slotSwap'
import PlayerMatchDetailSheet from './PlayerMatchDetailSheet'

function ordinal(n: number): string {
  const s = ['th', 'st', 'nd', 'rd']
  const v = n % 100
  return n + (s[(v - 20) % 10] ?? s[v] ?? s[0])
}

function SlotGameCard({ id, children }: { id: string; children: React.ReactNode }) {
  const { attributes, listeners, setNodeRef: setDragRef, transform, isDragging } = useDraggable({ id })
  const { setNodeRef: setDropRef, isOver } = useDroppable({ id })

  return (
    <div
      ref={setDropRef}
      className={isOver && !isDragging ? 'border border-dashed border-orange-400/60 rounded-lg' : 'border border-transparent rounded-lg'}
    >
      <div
        ref={setDragRef}
        style={transform ? { transform: CSS.Translate.toString(transform), position: 'relative', zIndex: 50 } : undefined}
        className={`flex items-center gap-2 ${isDragging ? 'opacity-40' : ''}`}
      >
        <span
          {...listeners}
          {...attributes}
          className="text-slate-500 hover:text-orange-400 cursor-grab active:cursor-grabbing text-base shrink-0 select-none touch-none px-0.5"
        >
          ⠿
        </span>
        {children}
      </div>
    </div>
  )
}

function StandingsTab({
  players,
  schedule,
  gameScores,
  absentPlayerIds,
}: {
  players: Player[]
  schedule: import('../store').ScheduleSlot[]
  gameScores: Record<string, GameScore>
  absentPlayerIds: string[]
}) {
  const absentList = players.filter(p => absentPlayerIds.includes(p.id))
  const standings = computeStandings(
    players.filter(p => !absentPlayerIds.includes(p.id)),
    schedule,
    gameScores,
  )
  const [selectedPlayer, setSelectedPlayer] = useState<{ standing: typeof standings[number]; rank: number } | null>(null)
  const hasScores = Object.keys(gameScores).length > 0

  if (!hasScores) {
    return (
      <div className="flex flex-col gap-4">
        <div className="flex items-center justify-center min-h-50">
          <p className="text-sm text-slate-500 text-center">Enter scores in the Schedule tab to see leaderboard.</p>
        </div>
        {absentList.length > 0 && (
          <div className="flex flex-col gap-1.5">
            <p className="text-[10px] font-bold text-slate-600 uppercase tracking-wider px-2">Absent</p>
            {absentList.map(p => (
              <div key={p.id} className="flex items-center gap-2 pl-2 pr-2 py-2 rounded-xl border border-slate-800/50 bg-slate-800/20">
                <span className="flex-1 text-sm font-medium text-slate-600 line-through">{p.name}</span>
                <span className="text-[10px] text-slate-700">absent</span>
              </div>
            ))}
          </div>
        )}
      </div>
    )
  }

  return (
    <div className="flex flex-col gap-1.5">
      {/* Tiebreaker order strip — hugs top divider */}
      <div className="flex justify-end gap-1 items-center pl-2 pr-2 -mt-4 pt-1 pb-3 text-[8px] text-slate-700">
        <span>ranked by:</span>
        <span className="font-semibold">W-L</span>
        <span>›</span>
        <span className="font-semibold">Diff</span>
        <span>›</span>
        <span className="font-semibold">Pts</span>
        <span>›</span>
        <span className="font-semibold">A-Z</span>
      </div>
      {/* Header */}
      <div className="flex items-center gap-2 pl-2 pr-2 mb-1">
        <span className="w-8 text-[10px] font-bold text-slate-600 text-center shrink-0">#</span>
        <span className="flex-1 text-[10px] font-bold text-slate-600">Name</span>
        <span className="w-11 text-[10px] font-bold text-slate-600 text-center shrink-0">W-L</span>
        <span className="w-9 text-[10px] font-bold text-slate-600 text-center shrink-0">Diff</span>
        <span className="w-9 text-[10px] font-bold text-slate-600 text-center shrink-0">Pts</span>
      </div>

      {standings.map((s, i) => {
        const rank = i + 1
        const isFirst = rank === 1
        const isSecond = rank === 2
        const isThird = rank === 3
        const isPodium = isFirst || isSecond || isThird
        const wlColor = s.wins > s.losses ? 'text-emerald-400' : s.losses > s.wins ? 'text-red-400' : 'text-slate-400'
        const diffColor = s.diff > 0 ? 'text-emerald-400' : s.diff < 0 ? 'text-red-400' : 'text-slate-400'
        const diffLabel = s.diff > 0 ? `+${s.diff}` : String(s.diff)

        const medal = isFirst ? '🥇' : isSecond ? '🥈' : isThird ? '🥉' : null

        const rowBg = isPodium
          ? 'bg-emerald-950/45 border-emerald-800/35'
          : 'bg-slate-800/30 border-slate-700/20'

        return (
          <div
            key={s.player.id}
            className={`flex items-center gap-2 pl-2 pr-2 py-2.5 rounded-xl border ${rowBg}`}
          >
            <div className="w-8 flex justify-center shrink-0">
              {medal
                ? <span className="text-lg leading-none">{medal}</span>
                : <span className="text-[11px] font-semibold text-slate-500">{ordinal(rank)}</span>
              }
            </div>
            <span
              className={`flex-1 min-w-0 truncate cursor-pointer active:opacity-70 ${isFirst ? 'text-sm font-bold text-emerald-300' : isPodium ? 'text-sm font-semibold text-emerald-100/80' : 'text-sm font-medium text-slate-400'}`}
              onClick={() => setSelectedPlayer({ standing: s, rank })}
            >
              {s.player.name}
            </span>
            <span className={`w-11 text-[11px] font-semibold text-center shrink-0 ${wlColor}`}>{s.wins}-{s.losses}</span>
            <span className={`w-9 text-[11px] font-semibold text-center shrink-0 ${diffColor}`}>{diffLabel}</span>
            <span className="w-9 text-[11px] font-semibold text-center shrink-0 text-slate-400">{s.pointsFor}</span>
          </div>
        )
      })}
      {absentList.length > 0 && (
        <>
          <div className="h-px bg-slate-800 my-1" />
          <p className="text-[10px] font-bold text-slate-600 uppercase tracking-wider px-2 mt-1">Absent</p>
          {absentList.map(p => (
            <div key={p.id} className="flex items-center gap-2 pl-2 pr-2 py-2 rounded-xl border border-slate-800/50 bg-slate-800/20">
              <span className="flex-1 text-sm font-medium text-slate-600 line-through">{p.name}</span>
              <span className="text-[10px] text-slate-700">absent</span>
            </div>
          ))}
        </>
      )}
      <PlayerMatchDetailSheet
        player={selectedPlayer?.standing ?? null}
        rank={selectedPlayer?.rank ?? 1}
        schedule={schedule}
        gameScores={gameScores}
        players={players}
        onClose={() => setSelectedPlayer(null)}
      />
    </div>
  )
}

function mergeCourtTimes(courtTimes: CourtTime[]): string {
  if (courtTimes.length === 0) return ''
  const ranges = courtTimes
    .map((ct) => ({ start: timeToMinutes(ct.start), end: timeToMinutes(ct.end) }))
    .sort((a, b) => a.start - b.start)
  const merged: { start: number; end: number }[] = []
  for (const r of ranges) {
    if (merged.length === 0 || r.start > merged[merged.length - 1].end) {
      merged.push({ ...r })
    } else {
      merged[merged.length - 1].end = Math.max(merged[merged.length - 1].end, r.end)
    }
  }
  return merged.map((r) => `${minutesToTime(r.start)}–${minutesToTime(r.end)}`).join(' · ')
}

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
  onLock,
  lockLoading = false,
}: {
  result: GeneratorResult
  playerMap: Map<string, Player>
  slotsPerCourt: number[]
  courtNames: string[]
  playedGames: string[]
  gameScores: Record<string, GameScore>
  onTogglePlayedGame: (key: string) => void
  onSetGameScore: (key: string, a: number, b: number) => void
  onClose?: () => void
  title: string
  date: string
  sessionStart: string
  slotMinutes: number
  courtTimes: CourtTime[]
  saving?: boolean
  standalone?: boolean
  onSwapPlayers?: (t1: SwapTarget, t2: SwapTarget) => void
  absentPlayers?: string[]
  onSetAbsent?: (nextAbsent: string[]) => void
  onReplacePlayer?: (playerId: string, newName: string) => void
  onSwapSlots?: (g1: SlotSwapTarget, g2: SlotSwapTarget) => void
  onSwapTeams?: (t1: TeamSwapTarget, t2: TeamSwapTarget) => void
  onChangePlayer?: (target: ChangeTarget, newName: string) => void
  onRefetch?: () => void
  isRefetching?: boolean
  onDelete?: () => void
  deleteLoading?: boolean
  locked?: boolean
  onLock?: () => void
  lockLoading?: boolean
}) {
  const courts = slotsPerCourt.length
  const maxSlots = Math.max(...slotsPerCourt)
  const played = new Set(playedArr)

  const [activeTab, setActiveTab] = useState<'schedule' | 'standings'>('schedule')
  const [expandedScore, setExpandedScore] = useState<string | null>(null)
  const [scoreError, setScoreError] = useState<string | null>(null)
  const [draftScores, setDraftScores] = useState<Record<string, { a: string; b: string }>>({})

  const [swapMode, setSwapMode] = useState(false)
  const [swapSelected, setSwapSelected] = useState<SwapTarget | null>(null)
  const [swapError, setSwapError] = useState<string | null>(null)
  const [pendingSwap, setPendingSwap] = useState<{ t1: SwapTarget; t2: SwapTarget } | null>(null)

  const [absentMode, setAbsentMode] = useState(false)
  const [absentPending, setAbsentPending] = useState<Set<string>>(new Set())

  const [replaceMode, setReplaceMode] = useState(false)
  const [replaceTarget, setReplaceTarget] = useState<string | null>(null)
  const [replaceName, setReplaceName] = useState('')

  const [slotSwapMode, setSlotSwapMode] = useState(false)
  const [pendingSlotSwap, setPendingSlotSwap] = useState<{ g1: SlotSwapTarget; g2: SlotSwapTarget } | null>(null)
  const [slotSwapError, setSlotSwapError] = useState<string | null>(null)

  const [teamSwapMode, setTeamSwapMode] = useState(false)
  const [teamSwapSelected, setTeamSwapSelected] = useState<TeamSwapTarget | null>(null)
  const [pendingTeamSwap, setPendingTeamSwap] = useState<{ t1: TeamSwapTarget; t2: TeamSwapTarget } | null>(null)
  const [teamSwapError, setTeamSwapError] = useState<string | null>(null)

  const [changeMode, setChangeMode] = useState(false)
  const [changeTarget, setChangeTarget] = useState<ChangeTarget | null>(null)
  const [changeName, setChangeName] = useState('')
  const [changeError, setChangeError] = useState<string | null>(null)

  const [actionsOpen, setActionsOpen] = useState(false)
  const [deleteConfirm, setDeleteConfirm] = useState(false)
  const [lockConfirm, setLockConfirm] = useState(false)

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

  function enterAbsentMode() {
    exitSwapMode()
    exitReplaceMode()
    exitSlotSwapMode()
    exitTeamSwapMode()
    exitChangeMode()
    setAbsentPending(new Set(absentPlayers))
    setAbsentMode(true)
  }

  function exitAbsentMode() {
    setAbsentMode(false)
    setAbsentPending(new Set())
  }

  function exitReplaceMode() {
    setReplaceMode(false)
    setReplaceTarget(null)
    setReplaceName('')
  }

  function enterReplaceMode() {
    exitSwapMode()
    exitAbsentMode()
    exitSlotSwapMode()
    exitTeamSwapMode()
    exitChangeMode()
    setReplaceMode(true)
  }

  function exitSlotSwapMode() {
    setSlotSwapMode(false)
    setPendingSlotSwap(null)
    setSlotSwapError(null)
  }

  function enterSlotSwapMode() {
    exitSwapMode()
    exitAbsentMode()
    exitReplaceMode()
    exitTeamSwapMode()
    exitChangeMode()
    setActionsOpen(false)
    setSlotSwapMode(true)
  }

  function exitTeamSwapMode() {
    setTeamSwapMode(false)
    setTeamSwapSelected(null)
    setPendingTeamSwap(null)
    setTeamSwapError(null)
  }

  function enterTeamSwapMode() {
    exitSwapMode()
    exitAbsentMode()
    exitReplaceMode()
    exitSlotSwapMode()
    exitChangeMode()
    setActionsOpen(false)
    setTeamSwapMode(true)
  }

  function exitChangeMode() {
    setChangeMode(false)
    setChangeTarget(null)
    setChangeName('')
    setChangeError(null)
  }

  function enterChangeMode() {
    exitSwapMode()
    exitAbsentMode()
    exitReplaceMode()
    exitSlotSwapMode()
    exitTeamSwapMode()
    setActionsOpen(false)
    setChangeMode(true)
  }

  function enterSwapMode() {
    exitAbsentMode()
    exitReplaceMode()
    exitSlotSwapMode()
    exitTeamSwapMode()
    exitChangeMode()
    setActionsOpen(false)
    setSwapMode(true)
  }

  function handleTeamClick(target: TeamSwapTarget) {
    if (!teamSwapMode) return
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
  const effectiveAbsent = absentMode ? absentPending : new Set(absentPlayers)

  // True when pending state differs from saved state
  const absentChanged = absentMode && (() => {
    const saved = new Set(absentPlayers)
    if (absentPending.size !== saved.size) return true
    for (const id of absentPending) if (!saved.has(id)) return true
    return false
  })()

  function exitSwapMode() {
    setSwapMode(false)
    setSwapSelected(null)
    setSwapError(null)
    setPendingSwap(null)
  }

  function handleChipClick(target: SwapTarget) {
    if (!swapMode) return
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
      if (targetGamePlayers.includes(swapSelected.playerId) || selectedGamePlayers.includes(target.playerId)) {
        setSwapError('One player already plays in the other\'s game')
        setSwapSelected(null)
        return
      }
    }
    setSwapError(null)
    setPendingSwap({ t1: swapSelected, t2: target })
    setSwapSelected(null)
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
  const isB2B = (id: string, t: number) => !!(slotPlayerSet.get(t - 1)?.has(id) || slotPlayerSet.get(t + 1)?.has(id))

  const name = (id: string, slot: number) => {
    const n = playerMap.get(id)?.name ?? id
    return isB2B(id, slot) ? `${n}*` : n
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
    if (a === b) { setScoreError('Scores can\'t be equal'); return false }
    setScoreError(null)
    onSetGameScore(key, a, b)
    return true
  }

  function handleScoreSave(key: string) {
    if (trySaveScore(key)) setExpandedScore(null)
  }

  return (
    <div className={standalone ? 'flex-1 flex flex-col bg-slate-950 overflow-hidden' : 'fixed inset-0 z-50 bg-slate-950 flex flex-col overflow-hidden'}>
      {/* Toolbar */}
      <div className="flex items-center justify-between px-5 py-3 border-b border-slate-800 shrink-0">
        <div className="flex items-center gap-3">
          <div className="flex gap-1">
            <button
              onClick={() => { setActiveTab('schedule'); exitSwapMode(); exitAbsentMode(); exitReplaceMode(); exitSlotSwapMode(); exitTeamSwapMode(); exitChangeMode() }}
              className={`text-xs font-semibold px-3 py-1.5 rounded-lg transition-colors ${activeTab === 'schedule' ? 'bg-indigo-900/60 border border-indigo-700 text-indigo-300' : 'text-slate-500 hover:text-slate-300'}`}
            >
              Schedule
            </button>
            <button
              onClick={() => { setActiveTab('standings'); exitSwapMode(); exitAbsentMode(); exitReplaceMode(); exitSlotSwapMode(); exitTeamSwapMode(); exitChangeMode() }}
              className={`text-xs font-semibold px-3 py-1.5 rounded-lg transition-colors ${activeTab === 'standings' ? 'bg-indigo-900/60 border border-indigo-700 text-indigo-300' : 'text-slate-500 hover:text-slate-300'}`}
            >
              Leaderboard
            </button>
          </div>
          {playedCount > 0 && (
            <span className="text-xs text-slate-500">
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
          {!locked && activeTab === 'schedule' && (onSwapPlayers || onSetAbsent || onReplacePlayer || onSwapSlots || onSwapTeams || onLock) && (
            swapMode || absentMode || replaceMode || slotSwapMode || teamSwapMode || changeMode ? (
              <button
                onClick={() => { exitSwapMode(); exitAbsentMode(); exitReplaceMode(); exitSlotSwapMode(); exitTeamSwapMode(); exitChangeMode(); setActionsOpen(false) }}
                className="text-xs font-semibold px-3 py-1.5 rounded-lg bg-slate-800 border border-slate-600 text-slate-300 hover:text-white transition-colors"
              >
                ✕<span className="hidden sm:inline"> Cancel</span>
              </button>
            ) : (
              <div className="relative">
                <button
                  onClick={() => setActionsOpen((v) => !v)}
                  className="text-xs font-semibold px-3 py-1.5 rounded-lg bg-slate-800/60 border border-slate-700 text-slate-300 hover:text-white transition-colors"
                >
                  ⋯<span className="hidden sm:inline"> Actions</span>
                </button>
                {actionsOpen && (
                  <>
                    <div className="fixed inset-0 z-10" onClick={() => setActionsOpen(false)} />
                    <div
                      className="absolute right-0 top-full mt-1 z-20 bg-slate-900 border border-slate-700 rounded-xl shadow-xl overflow-hidden"
                      style={{ minWidth: '160px' }}
                    >
                      {onSwapPlayers && (
                        <button
                          onClick={() => enterSwapMode()}
                          className="w-full text-left px-4 py-2.5 text-xs font-medium text-indigo-300 hover:bg-slate-800 transition-colors"
                        >
                          ⇄ Swap players
                        </button>
                      )}
                      {onSwapTeams && (
                        <button
                          onClick={() => enterTeamSwapMode()}
                          className="w-full text-left px-4 py-2.5 text-xs font-medium text-violet-400 hover:bg-slate-800 transition-colors border-t border-slate-800"
                        >
                          ⇄ Swap team
                        </button>
                      )}
                      {onReplacePlayer && (
                        <button
                          onClick={() => { setActionsOpen(false); enterReplaceMode() }}
                          className="w-full text-left px-4 py-2.5 text-xs font-medium text-emerald-400 hover:bg-slate-800 transition-colors border-t border-slate-800"
                        >
                          ↔ Replace player
                        </button>
                      )}
                      {onChangePlayer && (
                        <button
                          onClick={() => { setActionsOpen(false); enterChangeMode() }}
                          className="w-full text-left px-4 py-2.5 text-xs font-medium text-sky-400 hover:bg-slate-800 transition-colors border-t border-slate-800"
                        >
                          🔄 Change player
                        </button>
                      )}
                      {onSwapSlots && (
                        <button
                          onClick={() => { setActionsOpen(false); enterSlotSwapMode() }}
                          className="w-full text-left px-4 py-2.5 text-xs font-medium text-orange-400 hover:bg-slate-800 transition-colors border-t border-slate-800"
                        >
                          ↕ Switch slot
                        </button>
                      )}
                      {onSetAbsent && (
                        <button
                          onClick={() => { setActionsOpen(false); enterAbsentMode() }}
                          className="w-full text-left px-4 py-2.5 text-xs font-medium text-red-400 hover:bg-slate-800 transition-colors border-t border-slate-800"
                        >
                          👤 Mark absent
                        </button>
                      )}
                      {onLock && !locked && (
                        <button
                          onClick={() => { setActionsOpen(false); setLockConfirm(true) }}
                          className="w-full text-left px-4 py-2.5 text-xs font-medium text-amber-400 hover:bg-slate-800 transition-colors border-t border-slate-800"
                        >
                          🔒 Lock session
                        </button>
                      )}
                    </div>
                  </>
                )}
              </div>
            )
          )}
          {/* Delete button */}
          {onDelete && !deleteConfirm && (
            <button
              onClick={() => setDeleteConfirm(true)}
              className="text-slate-600 hover:text-red-400 px-2 py-1.5 rounded-lg hover:bg-red-950/30 transition-colors text-sm"
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
              className="text-xs text-slate-500 hover:text-slate-300 px-2 py-1.5 rounded-lg border border-slate-700 bg-slate-800/60 transition-colors"
            >
              ✕
            </button>
          )}
          {/* Lock confirmation */}
          {onLock && lockConfirm && !locked && (
            <>
              <button
                onClick={() => { onLock(); setLockConfirm(false) }}
                disabled={lockLoading}
                className="text-xs font-bold px-3 py-1.5 rounded-lg bg-amber-600 hover:bg-amber-500 text-white transition-colors disabled:opacity-50 flex items-center gap-1.5"
              >
                {lockLoading && <svg className="animate-spin w-3 h-3 shrink-0" viewBox="0 0 24 24" fill="none"><circle className="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" strokeWidth="4" /><path className="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4z" /></svg>}
                {lockLoading ? 'Locking…' : 'Confirm lock'}
              </button>
              <button
                onClick={() => setLockConfirm(false)}
                className="text-xs text-slate-500 hover:text-slate-300 px-2 py-1.5 rounded-lg border border-slate-700 bg-slate-800/60 transition-colors"
              >
                ✕
              </button>
            </>
          )}
          {/* Close button — only when onClose is provided */}
          {onClose && !deleteConfirm && !lockConfirm && (
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
            {title && <p className="text-white font-bold text-base leading-tight">{title}</p>}
            {date && (
              <p className="text-slate-400 text-xs mt-0.5">
                {new Date(date + 'T00:00:00').toLocaleDateString('en-GB', {
                  weekday: 'long',
                  day: 'numeric',
                  month: 'long',
                  year: 'numeric',
                })}
                {courtTimes.length > 0 && (
                  <span className="text-slate-600"> · {mergeCourtTimes(courtTimes)}</span>
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
      <div className={`flex-1 overflow-auto px-4 py-4 max-w-xl mx-auto w-full ${pendingSwap || absentChanged || pendingTeamSwap || changeTarget ? 'pb-24' : pendingSlotSwap ? 'pb-36' : ''}`}>
        {swapMode && !pendingSwap && (
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
        {absentMode && (
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
        {replaceMode && (
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
                        exitReplaceMode()
                      }
                    }}
                    placeholder="New name…"
                    autoFocus
                    className="flex-1 bg-slate-900 border border-emerald-800 rounded-lg px-3 py-1.5 text-xs text-white placeholder:text-slate-600 focus:outline-none focus:border-emerald-500"
                  />
                  <button
                    onClick={async () => {
                      if (!replaceName.trim()) return
                      await onReplacePlayer?.(replaceTarget, replaceName.trim())
                      exitReplaceMode()
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
        {slotSwapMode && (
          <div className="mb-3 rounded-lg bg-orange-950/30 border border-orange-900/40 px-3 py-2">
            {slotSwapError ? (
              <span className="text-xs text-red-400">{slotSwapError}</span>
            ) : (
              <span className="text-xs text-orange-300 font-medium">↕ Drag ⠿ to switch a game's slot</span>
            )}
          </div>
        )}
        {teamSwapMode && (
          <div className="mb-3 rounded-lg bg-violet-950/30 border border-violet-900/40 px-3 py-2">
            {teamSwapError ? (
              <span className="text-xs text-red-400">{teamSwapError}</span>
            ) : (
              <span className="text-xs text-violet-300 font-medium">⇄ Tap a team to select, then tap another team to swap</span>
            )}
          </div>
        )}
        {changeMode && (
          <div className="mb-3 rounded-lg bg-sky-950/30 border border-sky-900/40 px-3 py-2 flex flex-col gap-2">
            {changeTarget === null ? (
              <span className="text-xs text-sky-300 font-medium">Tap a player to change them out</span>
            ) : (
              <>
                <span className="text-xs text-sky-300 font-medium">
                  Change <strong>{playerMap.get(result.schedule.find(g => g.slot === changeTarget.slot && g.court === changeTarget.court)?.[changeTarget.team === 'A' ? 'teamA' : 'teamB'][changeTarget.index] ?? '')?.name ?? '?'}</strong> (Slot {changeTarget.slot + 1}, {courtLabel(changeTarget.court)}) to:
                </span>
                <div className="flex gap-2 items-center">
                  <input
                    type="text"
                    value={changeName}
                    onChange={(e) => { setChangeName(e.target.value); setChangeError(null) }}
                    onKeyDown={async (e) => {
                      if (e.key === 'Enter' && changeName.trim()) {
                        const conflict = detectChangeConflict(result.schedule, changeTarget, changeName.trim())
                        if (conflict) { setChangeError(`${changeName.trim()} is already in this game`); return }
                        await onChangePlayer?.(changeTarget, changeName.trim())
                        exitChangeMode()
                      }
                    }}
                    placeholder="New name…"
                    autoFocus
                    className="flex-1 bg-slate-900 border border-sky-800 rounded-lg px-3 py-1.5 text-xs text-white placeholder:text-slate-600 focus:outline-none focus:border-sky-500"
                  />
                  <button
                    onClick={async () => {
                      if (!changeName.trim()) return
                      const conflict = detectChangeConflict(result.schedule, changeTarget, changeName.trim())
                      if (conflict) { setChangeError(`${changeName.trim()} is already in this game`); return }
                      await onChangePlayer?.(changeTarget, changeName.trim())
                      exitChangeMode()
                    }}
                    disabled={!changeName.trim() || saving}
                    className="text-xs font-bold px-3 py-1.5 rounded-lg bg-sky-700 hover:bg-sky-600 text-white transition-colors disabled:opacity-50 disabled:cursor-not-allowed shrink-0 flex items-center gap-1.5"
                  >
                    {saving && <svg className="animate-spin w-3 h-3 shrink-0" viewBox="0 0 24 24" fill="none"><circle className="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" strokeWidth="4" /><path className="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4z" /></svg>}
                    {saving ? 'Saving…' : '✓ Change'}
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
        ) : (() => {
          const scheduleGrid = (
            <div className="flex flex-col divide-y divide-slate-800">
              {Array.from({ length: maxSlots }, (_, s) => {
                const games = (bySlot.get(s) ?? []).sort((a, b) => a.court - b.court)
                return (
                  <div key={s} className="flex items-start gap-4 py-4">
                    <div className="flex flex-col items-center w-4 shrink-0 pt-0.5 gap-0.5">
                      <span className="text-xs font-bold text-slate-600">#{s + 1}</span>
                      <span className="text-[8px] text-slate-700 font-medium leading-none">
                        {minutesToTime(timeToMinutes(sessionStart) + s * slotMinutes)}
                      </span>
                    </div>
                    <div className="flex flex-col gap-2.5 flex-1">
                      {games.map((g) => {
                        const key = `${s}-${g.court}`
                        const done = played.has(key)
                        const savedScore = gameScores[key]
                        const isOpen = expandedScore === key
                        const draft = draftScores[key] ?? { a: savedScore ? String(savedScore.a) : '', b: savedScore ? String(savedScore.b) : '' }
                        const teamANames = g.teamA.map((id) => playerMap.get(id)?.name ?? id).join(' & ')
                        const teamBNames = g.teamB.map((id) => playerMap.get(id)?.name ?? id).join(' & ')

                        const gameRow = (
                          <div className="flex flex-col gap-1">
                            {/* Game row header */}
                            <div
                              className={`flex items-center gap-2 select-none rounded-lg px-1 py-0.5 -mx-1 transition-colors ${done ? 'opacity-40' : 'hover:bg-slate-800/40'}`}
                            >
                              {/* Played checkbox */}
                              <div
                                className={`w-4 h-4 shrink-0 rounded border flex items-center justify-center transition-colors ${locked || swapMode || replaceMode || changeMode || slotSwapMode || teamSwapMode ? 'cursor-not-allowed opacity-25' : saving ? 'cursor-not-allowed opacity-50' : 'cursor-pointer'} ${done ? 'bg-emerald-600 border-emerald-500' : 'border-slate-600 bg-slate-800'}`}
                                onClick={() => { if (!locked && !saving && !swapMode && !replaceMode && !changeMode && !slotSwapMode && !teamSwapMode) onTogglePlayedGame(key) }}
                              >
                                {done && <span className="text-white text-[10px] font-bold leading-none">✓</span>}
                              </div>
                              {/* Teams */}
                              <div className="grid items-center gap-2 flex-1 min-w-0" style={{ gridTemplateColumns: 'auto 1fr auto 1fr' }}>
                                <span className="text-[10px] font-semibold text-slate-600 whitespace-nowrap">
                                  {courtLabel(g.court)}
                                </span>
                                {teamSwapMode ? (
                                  (() => {
                                    const tgt: TeamSwapTarget = { slot: s, court: g.court, team: 'A' }
                                    const isSelected = teamSwapSelected?.slot === s && teamSwapSelected?.court === g.court && teamSwapSelected?.team === 'A'
                                    const isPending = !!(pendingTeamSwap && (
                                      (pendingTeamSwap.t1.slot === s && pendingTeamSwap.t1.court === g.court && pendingTeamSwap.t1.team === 'A') ||
                                      (pendingTeamSwap.t2.slot === s && pendingTeamSwap.t2.court === g.court && pendingTeamSwap.t2.team === 'A')
                                    ))
                                    const isDimmed = !!pendingTeamSwap && !isPending
                                    return (
                                      <button
                                        onClick={() => !pendingTeamSwap && handleTeamClick(tgt)}
                                        disabled={!!pendingTeamSwap}
                                        className={`flex items-center gap-1 min-w-0 px-1.5 py-0.5 rounded-md border transition-colors ${
                                          isSelected || isPending
                                            ? 'bg-violet-900/50 border-violet-500 ring-1 ring-violet-500/60'
                                            : 'bg-slate-800/40 border-slate-700 hover:border-violet-400'
                                        } ${isDimmed ? 'opacity-30' : ''}`}
                                      >
                                        {g.teamA.map((id, i) => (
                                          <span key={i} className="flex items-center gap-1">
                                            {i > 0 && <span className="text-[10px] text-slate-600">&</span>}
                                            <span className="text-xs font-medium text-slate-200">{name(id, s)}</span>
                                          </span>
                                        ))}
                                      </button>
                                    )
                                  })()
                                ) : (
                                  <div className="flex items-center gap-1 min-w-0">
                                    {([0, 1] as const).map((i) => {
                                      const id = g.teamA[i]
                                      const n = name(id, s)
                                      const target: SwapTarget = { slot: s, court: g.court, playerId: id, team: 'A', index: i }
                                      const isSelected =
                                        (swapSelected?.slot === s && swapSelected?.court === g.court && swapSelected?.playerId === id) ||
                                        !!(pendingSwap && (
                                          (pendingSwap.t1.slot === s && pendingSwap.t1.court === g.court && pendingSwap.t1.playerId === id) ||
                                          (pendingSwap.t2.slot === s && pendingSwap.t2.court === g.court && pendingSwap.t2.playerId === id)
                                        ))
                                      const isDimmed = !!pendingSwap && !isSelected
                                      return (
                                        <span key={i} className={`flex items-center gap-1 ${isDimmed ? 'opacity-30' : ''}`}>
                                          {i > 0 && <span className="text-[10px] text-slate-600">&</span>}
                                          {replaceMode ? (
                                            <button
                                              onClick={() => {
                                                if (replaceTarget === id) {
                                                  setReplaceTarget(null)
                                                  setReplaceName('')
                                                } else {
                                                  setReplaceTarget(id)
                                                  setReplaceName('')
                                                }
                                              }}
                                              className={`text-xs font-medium px-1.5 py-0.5 rounded-md border transition-colors ${
                                                replaceTarget === id
                                                  ? 'bg-emerald-900/50 border-emerald-500 text-emerald-200 ring-1 ring-emerald-500/60'
                                                  : 'bg-slate-800/60 border-slate-600 text-slate-200 hover:border-emerald-400 hover:text-emerald-200'
                                              }`}
                                            >
                                              {n}
                                            </button>
                                          ) : changeMode ? (
                                            <button
                                              onClick={() => {
                                                const tgt: ChangeTarget = { slot: s, court: g.court, team: 'A', index: i }
                                                setChangeTarget(tgt)
                                                setChangeName('')
                                                setChangeError(null)
                                              }}
                                              className={`text-xs font-medium px-1.5 py-0.5 rounded-md border transition-colors ${
                                                changeTarget?.slot === s && changeTarget?.court === g.court && changeTarget?.team === 'A' && changeTarget?.index === i
                                                  ? 'bg-sky-900/50 border-sky-500 text-sky-200 ring-1 ring-sky-500/60'
                                                  : 'bg-slate-800/60 border-slate-600 text-slate-200 hover:border-sky-400 hover:text-sky-200'
                                              }`}
                                            >
                                              {n}
                                            </button>
                                          ) : swapMode && !done && !pendingSwap ? (
                                            <button
                                              onClick={() => handleChipClick(target)}
                                              className={`text-xs font-medium px-1.5 py-0.5 rounded-md border transition-colors ${
                                                isSelected
                                                  ? 'bg-indigo-900/50 border-indigo-500 text-indigo-200 ring-1 ring-indigo-500/60'
                                                  : 'bg-slate-800/60 border-slate-600 text-slate-200 hover:border-indigo-400 hover:text-indigo-200'
                                              }`}
                                            >
                                              {n}
                                            </button>
                                          ) : swapMode && !done && pendingSwap ? (
                                            <span className={`text-xs font-medium px-1.5 py-0.5 rounded-md border ${
                                              isSelected
                                                ? 'bg-indigo-900/50 border-indigo-500 text-indigo-200 ring-1 ring-indigo-500/60'
                                                : effectiveAbsent.has(id)
                                                  ? 'border-transparent text-slate-500 line-through'
                                                  : 'border-transparent text-white'
                                            }`}>{n}</span>
                                          ) : (
                                            <span className={`text-xs font-medium px-1.5 py-0.5 rounded-md border ${
                                              effectiveAbsent.has(id)
                                                ? 'border-transparent text-slate-500 line-through'
                                                : done
                                                  ? 'border-transparent text-slate-400 line-through'
                                                  : 'border-transparent text-white'
                                            }`}>{n}</span>
                                          )}
                                        </span>
                                      )
                                    })}
                                  </div>
                                )}
                                <span className="text-slate-600 text-xs text-center">vs</span>
                                {teamSwapMode ? (
                                  (() => {
                                    const tgt: TeamSwapTarget = { slot: s, court: g.court, team: 'B' }
                                    const isSelected = teamSwapSelected?.slot === s && teamSwapSelected?.court === g.court && teamSwapSelected?.team === 'B'
                                    const isPending = !!(pendingTeamSwap && (
                                      (pendingTeamSwap.t1.slot === s && pendingTeamSwap.t1.court === g.court && pendingTeamSwap.t1.team === 'B') ||
                                      (pendingTeamSwap.t2.slot === s && pendingTeamSwap.t2.court === g.court && pendingTeamSwap.t2.team === 'B')
                                    ))
                                    const isDimmed = !!pendingTeamSwap && !isPending
                                    return (
                                      <button
                                        onClick={() => !pendingTeamSwap && handleTeamClick(tgt)}
                                        disabled={!!pendingTeamSwap}
                                        className={`flex items-center gap-1 min-w-0 px-1.5 py-0.5 rounded-md border transition-colors ${
                                          isSelected || isPending
                                            ? 'bg-violet-900/50 border-violet-500 ring-1 ring-violet-500/60'
                                            : 'bg-slate-800/40 border-slate-700 hover:border-violet-400'
                                        } ${isDimmed ? 'opacity-30' : ''}`}
                                      >
                                        {g.teamB.map((id, i) => (
                                          <span key={i} className="flex items-center gap-1">
                                            {i > 0 && <span className="text-[10px] text-slate-600">&</span>}
                                            <span className="text-xs font-medium text-slate-200">{name(id, s)}</span>
                                          </span>
                                        ))}
                                      </button>
                                    )
                                  })()
                                ) : (
                                  <div className="flex items-center gap-1 min-w-0">
                                    {([0, 1] as const).map((i) => {
                                      const id = g.teamB[i]
                                      const n = name(id, s)
                                      const target: SwapTarget = { slot: s, court: g.court, playerId: id, team: 'B', index: i }
                                      const isSelected =
                                        (swapSelected?.slot === s && swapSelected?.court === g.court && swapSelected?.playerId === id) ||
                                        !!(pendingSwap && (
                                          (pendingSwap.t1.slot === s && pendingSwap.t1.court === g.court && pendingSwap.t1.playerId === id) ||
                                          (pendingSwap.t2.slot === s && pendingSwap.t2.court === g.court && pendingSwap.t2.playerId === id)
                                        ))
                                      const isDimmed = !!pendingSwap && !isSelected
                                      return (
                                        <span key={i} className={`flex items-center gap-1 ${isDimmed ? 'opacity-30' : ''}`}>
                                          {i > 0 && <span className="text-[10px] text-slate-600">&</span>}
                                          {replaceMode ? (
                                            <button
                                              onClick={() => {
                                                if (replaceTarget === id) {
                                                  setReplaceTarget(null)
                                                  setReplaceName('')
                                                } else {
                                                  setReplaceTarget(id)
                                                  setReplaceName('')
                                                }
                                              }}
                                              className={`text-xs font-medium px-1.5 py-0.5 rounded-md border transition-colors ${
                                                replaceTarget === id
                                                  ? 'bg-emerald-900/50 border-emerald-500 text-emerald-200 ring-1 ring-emerald-500/60'
                                                  : 'bg-slate-800/60 border-slate-600 text-slate-200 hover:border-emerald-400 hover:text-emerald-200'
                                              }`}
                                            >
                                              {n}
                                            </button>
                                          ) : changeMode ? (
                                            <button
                                              onClick={() => {
                                                const tgt: ChangeTarget = { slot: s, court: g.court, team: 'B', index: i }
                                                setChangeTarget(tgt)
                                                setChangeName('')
                                                setChangeError(null)
                                              }}
                                              className={`text-xs font-medium px-1.5 py-0.5 rounded-md border transition-colors ${
                                                changeTarget?.slot === s && changeTarget?.court === g.court && changeTarget?.team === 'B' && changeTarget?.index === i
                                                  ? 'bg-sky-900/50 border-sky-500 text-sky-200 ring-1 ring-sky-500/60'
                                                  : 'bg-slate-800/60 border-slate-600 text-slate-200 hover:border-sky-400 hover:text-sky-200'
                                              }`}
                                            >
                                              {n}
                                            </button>
                                          ) : swapMode && !done && !pendingSwap ? (
                                            <button
                                              onClick={() => handleChipClick(target)}
                                              className={`text-xs font-medium px-1.5 py-0.5 rounded-md border transition-colors ${
                                                isSelected
                                                  ? 'bg-indigo-900/50 border-indigo-500 text-indigo-200 ring-1 ring-indigo-500/60'
                                                  : 'bg-slate-800/60 border-slate-600 text-slate-200 hover:border-indigo-400 hover:text-indigo-200'
                                              }`}
                                            >
                                              {n}
                                            </button>
                                          ) : swapMode && !done && pendingSwap ? (
                                            <span className={`text-xs font-medium px-1.5 py-0.5 rounded-md border ${
                                              isSelected
                                                ? 'bg-indigo-900/50 border-indigo-500 text-indigo-200 ring-1 ring-indigo-500/60'
                                                : effectiveAbsent.has(id)
                                                  ? 'border-transparent text-slate-500 line-through'
                                                  : 'border-transparent text-white'
                                            }`}>{n}</span>
                                          ) : (
                                            <span className={`text-xs font-medium px-1.5 py-0.5 rounded-md border ${
                                              effectiveAbsent.has(id)
                                                ? 'border-transparent text-slate-500 line-through'
                                                : done
                                                  ? 'border-transparent text-slate-400 line-through'
                                                  : 'border-transparent text-white'
                                            }`}>{n}</span>
                                          )}
                                        </span>
                                      )
                                    })}
                                  </div>
                                )}
                              </div>
                              {/* Score toggle / saved score */}
                              {!changeMode && !swapMode && !replaceMode && !slotSwapMode && !teamSwapMode && (savedScore && !isOpen ? (
                                <button
                                  onClick={() => { if (!locked) { setExpandedScore(key); setScoreError(null); setDraftScores((d) => ({ ...d, [key]: { a: String(savedScore.a), b: String(savedScore.b) } })) } }}
                                  className={`text-[11px] font-bold shrink-0 whitespace-nowrap ${locked ? 'text-slate-500 cursor-default' : 'text-emerald-400 hover:text-emerald-300'}`}
                                >
                                  {savedScore.a}–{savedScore.b}
                                </button>
                              ) : !locked ? (
                                <button
                                  onClick={() => {
                                    if (isOpen) { setExpandedScore(null); setScoreError(null) }
                                    else { setExpandedScore(key); setScoreError(null); setDraftScores((d) => ({ ...d, [key]: draft })) }
                                  }}
                                  className="text-[10px] text-slate-600 hover:text-slate-400 shrink-0 whitespace-nowrap transition-colors"
                                >
                                  {isOpen ? '▲ score' : '+ score'}
                                </button>
                              ) : null)}
                            </div>

                            {/* Expandable score panel */}
                            {isOpen && (
                              <div className="ml-6 bg-slate-900 border border-indigo-800/60 rounded-lg px-3 py-2.5 flex flex-col gap-2">
                                <div className="flex items-center justify-center gap-3">
                                  <div className="flex flex-col items-center gap-1">
                                    <span className="text-[10px] text-slate-500 truncate max-w-20 text-center">{teamANames}</span>
                                    <input
                                      type="number"
                                      min={0}
                                      max={99}
                                      value={draft.a}
                                      onChange={(e) => setDraftScores((d) => ({ ...d, [key]: { ...(d[key] ?? draft), a: e.target.value } }))}
                                      className="w-14 bg-slate-800 border border-indigo-700 rounded-lg px-2 py-1.5 text-white font-bold text-lg text-center focus:outline-none focus:border-indigo-500"
                                    />
                                  </div>
                                  <span className="text-slate-600 font-bold text-lg mt-4">–</span>
                                  <div className="flex flex-col items-center gap-1">
                                    <span className="text-[10px] text-slate-500 truncate max-w-20 text-center">{teamBNames}</span>
                                    <input
                                      type="number"
                                      min={0}
                                      max={99}
                                      value={draft.b}
                                      onChange={(e) => setDraftScores((d) => ({ ...d, [key]: { ...(d[key] ?? draft), b: e.target.value } }))}
                                      className="w-14 bg-slate-800 border border-slate-700 rounded-lg px-2 py-1.5 text-slate-300 font-bold text-lg text-center focus:outline-none focus:border-indigo-500"
                                    />
                                  </div>
                                </div>
                                <div className="flex flex-col items-center gap-1">
                                  {scoreError && (
                                    <p className="text-[10px] text-red-400 text-center">{scoreError}</p>
                                  )}
                                  <button
                                    onClick={() => handleScoreSave(key)}
                                    disabled={saving}
                                    className="px-6 py-1 rounded-lg bg-emerald-700 hover:bg-emerald-600 text-white text-xs font-bold transition-colors disabled:opacity-50 disabled:cursor-not-allowed flex items-center gap-1.5"
                                  >
                                    {saving && <svg className="animate-spin w-3 h-3 shrink-0" viewBox="0 0 24 24" fill="none"><circle className="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" strokeWidth="4" /><path className="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4z" /></svg>}
                                    {saving ? 'Saving…' : '✓ Save'}
                                  </button>
                                </div>
                              </div>
                            )}
                          </div>
                        )
                        return slotSwapMode ? (
                          <SlotGameCard key={key} id={key}>
                            {gameRow}
                          </SlotGameCard>
                        ) : (
                          <div key={key}>{gameRow}</div>
                        )
                      })}
                    </div>
                  </div>
                )
              })}
            </div>
          )
          return slotSwapMode ? (
            <DndContext sensors={sensors} onDragEnd={handleDragEnd}>
              {scheduleGrid}
            </DndContext>
          ) : scheduleGrid
        })()}

        {/* Player Stats — shown below schedule */}
        {activeTab === 'schedule' && (() => {
          const players = [...playerMap.values()]
          if (players.length === 0 || result.schedule.length === 0) return null

          // Compute stats from schedule
          const playCount: Record<string, number> = Object.fromEntries(players.map(p => [p.id, 0]))
          const partnerWith: Record<string, Record<string, number>> = {}
          const facedBy: Record<string, Record<string, number>> = {}

          for (const g of result.schedule) {
            const allPlayers = [...g.teamA, ...g.teamB]
            for (const id of allPlayers) playCount[id]++

            // Partners
            const inc2 = (obj: Record<string, Record<string, number>>, a: string, b: string) => {
              obj[a] ??= {}; obj[a][b] = (obj[a][b] ?? 0) + 1
              obj[b] ??= {}; obj[b][a] = (obj[b][a] ?? 0) + 1
            }
            inc2(partnerWith, g.teamA[0], g.teamA[1])
            inc2(partnerWith, g.teamB[0], g.teamB[1])

            // Opponents
            for (const a of g.teamA) {
              for (const b of g.teamB) {
                facedBy[a] ??= {}; facedBy[a][b] = (facedBy[a][b] ?? 0) + 1
                facedBy[b] ??= {}; facedBy[b][a] = (facedBy[b][a] ?? 0) + 1
              }
            }
          }

          // Compute sit count
          const slotPlayerSet = new Map<number, Set<string>>()
          for (const g of result.schedule) {
            const set = slotPlayerSet.get(g.slot) ?? new Set<string>()
            g.teamA.forEach(id => set.add(id)); g.teamB.forEach(id => set.add(id))
            slotPlayerSet.set(g.slot, set)
          }
          const maxSlots = Math.max(...result.schedule.map(g => g.slot)) + 1
          const sitCount: Record<string, number> = Object.fromEntries(players.map(p => [p.id, 0]))
          for (let t = 0; t < maxSlots; t++) {
            const playing = slotPlayerSet.get(t) ?? new Set<string>()
            for (const p of players) {
              if (!playing.has(p.id)) sitCount[p.id]++
            }
          }

          const idealPlays = (result.schedule.length * 4) / players.length

          return (
            <div className="mt-6 bg-slate-900 border border-slate-800 rounded-2xl p-3 flex flex-col gap-2">
              <div className="flex items-center justify-between">
                <span className="text-sm font-semibold text-white">Player Stats</span>
                <span className="text-xs text-slate-500">target ~{idealPlays.toFixed(1)} plays</span>
              </div>
              <div className="grid grid-cols-1 gap-y-2">
                {players
                  .sort((a, b) => (playCount[b.id] ?? 0) - (playCount[a.id] ?? 0))
                  .map((p) => {
                    const plays = playCount[p.id] ?? 0
                    const sits = sitCount[p.id] ?? 0
                    const partners = Object.keys(partnerWith[p.id] ?? {}).length
                    const opponents = Object.keys(facedBy[p.id] ?? {}).length
                    const over = plays > Math.ceil(idealPlays)
                    const under = plays < Math.floor(idealPlays)
                    return (
                      <div key={p.id} className="flex items-center gap-2">
                        <span className="text-xs text-slate-300 w-20 truncate">{p.name}</span>
                        <span className={`text-xs font-bold w-8 ${over ? 'text-amber-400' : under ? 'text-sky-400' : 'text-emerald-400'}`}>
                          {plays}×
                        </span>
                        <span className="text-[10px] text-slate-600">
                          {sits} sit · {partners} P · {opponents} O
                        </span>
                      </div>
                    )
                  })}
              </div>
              <p className="text-[10px] text-slate-600">P = unique partners · O = unique opponents faced</p>
            </div>
          )
        })()}
      </div>

      {/* Swap confirm bar */}
      {pendingSwap && (
        <div className="fixed bottom-0 left-0 right-0 z-50 bg-slate-950 border-t border-indigo-900/40 px-4 py-3">
          <div className="max-w-xl mx-auto">
          <div className="bg-indigo-950/50 border border-indigo-800/50 rounded-xl px-3 py-2.5 flex items-center gap-3">
            <div className="flex-1 min-w-0">
              <p className="text-xs font-semibold text-slate-200 truncate">
                <span className="text-indigo-200">{playerMap.get(pendingSwap.t1.playerId)?.name}</span>
                {' '}⇄{' '}
                <span className="text-indigo-200">{playerMap.get(pendingSwap.t2.playerId)?.name}</span>
              </p>
              <p className="text-[10px] text-red-400 mt-0.5">⚠ Cannot be undone</p>
            </div>
            <button
              onClick={() => setPendingSwap(null)}
              className="text-xs text-slate-500 hover:text-slate-300 px-2 py-1.5 rounded-lg border border-slate-700 bg-slate-800/60 transition-colors shrink-0"
            >
              ✕
            </button>
            <button
              onClick={() => { onSwapPlayers?.(pendingSwap.t1, pendingSwap.t2); exitSwapMode() }}
              disabled={saving}
              className="text-xs font-bold px-4 py-1.5 rounded-lg bg-indigo-600 hover:bg-indigo-500 text-white transition-colors disabled:opacity-50 shrink-0 flex items-center gap-1.5"
            >
              {saving && <svg className="animate-spin w-3 h-3 shrink-0" viewBox="0 0 24 24" fill="none"><circle className="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" strokeWidth="4" /><path className="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4z" /></svg>}
              {saving ? 'Saving…' : 'Confirm'}
            </button>
          </div>
          </div>
        </div>
      )}
      {/* Absent confirm bar */}
      {absentChanged && (
        <div className="fixed bottom-0 left-0 right-0 z-50 bg-slate-950 border-t border-red-900/40 px-4 py-3">
          <div className="max-w-xl mx-auto">
          <div className="bg-red-950/40 border border-red-800/50 rounded-xl px-3 py-2.5 flex items-center gap-3">
            <div className="flex-1 min-w-0">
              <p className="text-xs font-semibold text-slate-200 truncate">
                {absentPending.size === 0
                  ? 'Remove all absent tags'
                  : [...playerMap.values()].filter(p => absentPending.has(p.id)).map(p => p.name).join(', ')}
              </p>
              <p className="text-[10px] text-slate-500 mt-0.5">Excluded from leaderboard</p>
            </div>
            <button
              onClick={exitAbsentMode}
              className="text-xs text-slate-500 hover:text-slate-300 px-2 py-1.5 rounded-lg border border-slate-700 bg-slate-800/60 transition-colors shrink-0"
            >
              ✕
            </button>
            <button
              onClick={() => { onSetAbsent?.([...absentPending]); exitAbsentMode() }}
              disabled={saving}
              className="text-xs font-bold px-4 py-1.5 rounded-lg bg-red-700 hover:bg-red-600 text-white transition-colors disabled:opacity-50 shrink-0 flex items-center gap-1.5"
            >
              {saving && <svg className="animate-spin w-3 h-3 shrink-0" viewBox="0 0 24 24" fill="none"><circle className="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" strokeWidth="4" /><path className="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4z" /></svg>}
              {saving ? 'Saving…' : 'Confirm'}
            </button>
          </div>
          </div>
        </div>
      )}
      {/* Slot swap confirm bar */}
      {pendingSlotSwap && (() => {
        const slotInfo = (t: { slot: number; court: number }) => {
          const game = result.schedule.find((g) => g.slot === t.slot && g.court === t.court)
          const label = `Slot ${t.slot + 1} - ${courtLabel(t.court)}`
          if (!game) return { label, players: '' }
          const aNames = game.teamA.map((id) => playerMap.get(id)?.name ?? id).join(' & ')
          const bNames = game.teamB.map((id) => playerMap.get(id)?.name ?? id).join(' & ')
          return { label, players: `${aNames} vs ${bNames}` }
        }
        const s1 = slotInfo(pendingSlotSwap.g1)
        const s2 = slotInfo(pendingSlotSwap.g2)
        return (
          <div className="fixed bottom-0 left-0 right-0 z-50 bg-slate-950 border-t border-orange-900/40 px-4 pt-3 pb-4">
            <div className="max-w-xl mx-auto flex flex-col gap-2.5">
              <div className="bg-orange-950/40 border border-orange-800/40 rounded-xl px-3 py-2.5 flex flex-col gap-1.5">
                <div className="flex items-start gap-2">
                  <div className="flex-1 min-w-0">
                    <span className="text-[10px] font-bold text-orange-400 uppercase tracking-wider">{s1.label}</span>
                    {s1.players && <p className="text-xs text-slate-200 leading-snug mt-0.5">{s1.players}</p>}
                  </div>
                </div>
                <div className="flex items-center gap-1.5">
                  <div className="h-px flex-1 bg-orange-900/40" />
                  <span className="text-[10px] text-orange-500 font-bold">↕ switch</span>
                  <div className="h-px flex-1 bg-orange-900/40" />
                </div>
                <div className="flex-1 min-w-0">
                  <span className="text-[10px] font-bold text-orange-400 uppercase tracking-wider">{s2.label}</span>
                  {s2.players && <p className="text-xs text-slate-200 leading-snug mt-0.5">{s2.players}</p>}
                </div>
              </div>
              <div className="flex items-center gap-2">
                <span className="text-[10px] text-red-400 flex-1">⚠ Cannot be undone</span>
                <button
                  onClick={() => setPendingSlotSwap(null)}
                  className="text-xs text-slate-400 hover:text-slate-200 px-3 py-1.5 rounded-lg border border-slate-700 bg-slate-800/60 transition-colors shrink-0"
                >
                  Cancel
                </button>
                <button
                  onClick={() => { onSwapSlots?.(pendingSlotSwap.g1, pendingSlotSwap.g2); exitSlotSwapMode() }}
                  disabled={saving}
                  className="text-xs font-bold px-5 py-1.5 rounded-lg bg-orange-600 hover:bg-orange-500 text-white transition-colors disabled:opacity-50 shrink-0 flex items-center gap-1.5"
                >
                  {saving && <svg className="animate-spin w-3 h-3 shrink-0" viewBox="0 0 24 24" fill="none"><circle className="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" strokeWidth="4" /><path className="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4z" /></svg>}
                  {saving ? 'Saving…' : 'Confirm'}
                </button>
              </div>
            </div>
          </div>
        )
      })()}
      {/* Team swap confirm bar */}
      {pendingTeamSwap && (() => {
        const t1game = result.schedule.find(g => g.slot === pendingTeamSwap.t1.slot && g.court === pendingTeamSwap.t1.court)
        const t2game = result.schedule.find(g => g.slot === pendingTeamSwap.t2.slot && g.court === pendingTeamSwap.t2.court)
        const t1names = t1game
          ? (pendingTeamSwap.t1.team === 'A' ? t1game.teamA : t1game.teamB).map(id => playerMap.get(id)?.name ?? id).join(' & ')
          : '?'
        const t2names = t2game
          ? (pendingTeamSwap.t2.team === 'A' ? t2game.teamA : t2game.teamB).map(id => playerMap.get(id)?.name ?? id).join(' & ')
          : '?'
        return (
          <div className="fixed bottom-0 left-0 right-0 z-50 bg-slate-950 border-t border-violet-900/40 px-4 py-3">
            <div className="max-w-xl mx-auto">
              <div className="bg-violet-950/50 border border-violet-800/50 rounded-xl px-3 py-2.5 flex items-center gap-3">
                <div className="flex-1 min-w-0">
                  <p className="text-xs font-semibold text-slate-200 truncate">
                    <span className="text-violet-200">{t1names}</span>
                    {' '}⇄{' '}
                    <span className="text-violet-200">{t2names}</span>
                  </p>
                  <p className="text-[10px] text-red-400 mt-0.5">⚠ Cannot be undone</p>
                </div>
                <button
                  onClick={exitTeamSwapMode}
                  className="text-xs text-slate-500 hover:text-slate-300 px-2 py-1.5 rounded-lg border border-slate-700 bg-slate-800/60 transition-colors shrink-0"
                >
                  ✕
                </button>
                <button
                  onClick={() => { onSwapTeams?.(pendingTeamSwap.t1, pendingTeamSwap.t2); exitTeamSwapMode() }}
                  disabled={saving}
                  className="text-xs font-bold px-4 py-1.5 rounded-lg bg-violet-600 hover:bg-violet-500 text-white transition-colors disabled:opacity-50 shrink-0 flex items-center gap-1.5"
                >
                  {saving && <svg className="animate-spin w-3 h-3 shrink-0" viewBox="0 0 24 24" fill="none"><circle className="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" strokeWidth="4" /><path className="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4z" /></svg>}
                  {saving ? 'Saving…' : 'Confirm'}
                </button>
              </div>
            </div>
          </div>
        )
      })()}
    </div>
  )
}
