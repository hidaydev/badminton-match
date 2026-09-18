import { useMemo, useState } from 'react'
import {
  PointerSensor,
  TouchSensor,
  useSensor,
  useSensors,
} from '@dnd-kit/core'
import type { GeneratorResult } from '../generator'
import type { Player, GameScore, CourtTime } from '../types'
import { formatMergedCourtTimes } from '../utils/time'
import { courtLabel } from '../utils/courtLabel'
import type { SwapTarget, TeamSwapTarget } from '../utils/swap'
import { validateChangeName } from '../utils/swap'
import type { SlotSwapTarget } from '../utils/slotSwap'
import ConfirmBars from './summary/ConfirmBars'
import ActionsMenu from './summary/ActionsMenu'
import PlayerStatsPanel from './summary/PlayerStatsPanel'
import ScheduleGrid from './summary/ScheduleGrid'
import StandingsTab from './summary/StandingsTab'
import { useScoreDraft } from './summary/useScoreDraft'
import { useSummaryEditModes } from './summary/useSummaryEditModes'
import { useEscapeKey } from '../hooks/useEscapeKey'

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
  skippedPlayers?: Record<string, string[]>
}

/** Edit callback props for SummaryModal (all optional for read-only views) */
interface SummaryModalEditProps {
  onTogglePlayedGame?: (key: string) => void
  onSetGameScore?: (key: string, a: number, b: number) => void
  onSwapPlayers?: (t1: SwapTarget, t2: SwapTarget) => void
  onSetAbsent?: (nextAbsent: string[]) => void
  onSetGameSkipped?: (key: string, playerIds: string[]) => void
  onReplacePlayer?: (playerId: string, newName: string) => void
  onSwapSlots?: (g1: SlotSwapTarget, g2: SlotSwapTarget) => void
  onSwapTeams?: (t1: TeamSwapTarget, t2: TeamSwapTarget) => void
  onChangePlayer?: (target: SwapTarget, newName: string) => void
  onRefetch?: () => void
  isRefetching?: boolean
  onDelete?: () => void
  deleteLoading?: boolean
  onClose?: () => void
  saving?: boolean
}

type SummaryModalProps = SummaryModalBaseProps & SummaryModalEditProps

// Module-scope defaults: fresh literals would change identity every render and
// defeat the downstream memo chain (effectiveAbsent/effectiveSkipped).
const EMPTY_STRING_ARRAY: string[] = []
const EMPTY_SKIPPED_RECORD: Record<string, string[]> = {}

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
  absentPlayers = EMPTY_STRING_ARRAY,
  skippedPlayers = EMPTY_SKIPPED_RECORD,
  onSetAbsent,
  onSetGameSkipped,
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
  const played = new Set(playedArr)

  const [activeTab, setActiveTab] = useState<'schedule' | 'standings'>('schedule')
  // Escape menutup modal (tidak saat standalone/full-page).
  useEscapeKey(() => onClose?.(), !!onClose && !standalone)

  const score = useScoreDraft(onSetGameScore)
  const { expandedScore, setExpandedScore, scoreError, setScoreError, draftScores, setDraftScores, handleScoreSave } = score

  // Mode edit (swap/absent/skip/replace/slotSwap/teamSwap/change) — lihat hook.
  const modes = useSummaryEditModes({
    schedule: result.schedule,
    playerMap,
    absentPlayers,
    skippedPlayers,
    onExitExtra: score.reset,
    onSwapPlayers,
    onSetAbsent,
    onSetGameSkipped,
    onSwapSlots,
    onSwapTeams,
    onChangePlayer,
  })
  const {
    mode,
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
  } = modes

  // Prop stabil untuk StandingsTab — tanpa ini, useMemo di dalamnya recompute
  // computeStandings tiap render karena array/objek selalu identitas baru.
  const standingsPlayers = useMemo(() => [...playerMap.values()], [playerMap])
  const standingsAbsentIds = useMemo(() => [...effectiveAbsent], [effectiveAbsent])
  const standingsSkipped = useMemo(() => {
    const out: Record<string, string[]> = {}
    for (const [k, s] of Object.entries(effectiveSkipped)) out[k] = [...s]
    return out
  }, [effectiveSkipped])

  const [highlightedPlayerId, setHighlightedPlayerId] = useState<string | null>(null)
  const [deleteConfirm, setDeleteConfirm] = useState(false)

  const sensors = useSensors(
    useSensor(PointerSensor),
    useSensor(TouchSensor, { activationConstraint: { delay: 200, tolerance: 5 } }),
  )

  const totalGames = result.schedule.length
  const playedCount = played.size

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
          {!locked && activeTab === 'schedule' && (onSwapPlayers || onSetAbsent || onSetGameSkipped || onReplacePlayer || onSwapSlots || onSwapTeams) && (
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
                onEnterSkipMode={() => { setActionsOpen(false); enterSkipMode() }}
                hasSwapPlayers={!!onSwapPlayers}
                hasSwapTeams={!!onSwapTeams}
                hasReplacePlayer={!!onReplacePlayer}
                hasChangePlayer={!!onChangePlayer}
                hasSwapSlots={!!onSwapSlots}
                hasSetAbsent={!!onSetAbsent}
                hasSetSkipped={!!onSetGameSkipped}
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
      <div className={`flex-1 overflow-auto px-4 py-4 max-w-xl mx-auto w-full ${pendingSwap || absentChanged || skipChanged || pendingTeamSwap || pendingChange ? 'pb-24' : pendingSlotSwap ? 'pb-36' : ''}`}>
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
            <span className="text-[11px] text-red-400/70">whole session — {totalGames} games</span>
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
        {mode === 'skip' && (
          <div className="mb-3 rounded-lg bg-amber-950/30 border border-amber-900/40 px-3 py-2 flex flex-col gap-1">
            <span className="text-xs text-amber-300 font-medium">
              {flatSkippedCount > 0
                ? `${flatSkippedCount} skipped — tap chip in a game to toggle (excludes from rating)`
                : 'Tap a player chip inside a game to skip them for THAT game only'}
            </span>
            <span className="text-[11px] text-amber-400/70">one game only — player excluded from rating</span>
            {skipChanged && (
              <span className="text-[10px] text-amber-300">
                {[...skipPending.entries()].map(([k, s]) => `${k}: ${[...s].map(id => playerMap.get(id)?.name ?? id).join(', ')}`).join(' · ')}
              </span>
            )}
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
                  Change <strong>{playerMap.get(changeTarget.playerId)?.name ?? '?'}</strong> (Slot {changeTarget.slot + 1}, {courtLabel(courtNames, changeTarget.court)}) to:
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
            players={standingsPlayers}
            schedule={result.schedule}
            gameScores={gameScores}
            absentPlayerIds={standingsAbsentIds}
            skippedPlayers={standingsSkipped}
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
            effectiveSkipped={effectiveSkipped}
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
            onSkipToggle={toggleSkipForGame}
            setExpandedScore={setExpandedScore}
            setScoreError={setScoreError}
            setDraftScores={setDraftScores}
            highlightedPlayerId={highlightedPlayerId}
          />
        )}

        {/* Player Stats — shown below schedule */}
        {activeTab === 'schedule' && (
          <PlayerStatsPanel
            schedule={result.schedule}
            playerMap={playerMap}
            absentPlayers={absentPlayers}
            standalone={standalone}
            highlightedPlayerId={highlightedPlayerId}
            onSelectPlayer={(id) => setHighlightedPlayerId((prev) => prev === id ? null : id)}
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
        skipChanged={skipChanged}
        skipPending={skipPending}
        onCancelSkip={exitCurrentMode}
        onConfirmSkip={handleConfirmSkip}
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
        courtLabel={(i) => courtLabel(courtNames, i)}
      />
    </div>
  )
}
