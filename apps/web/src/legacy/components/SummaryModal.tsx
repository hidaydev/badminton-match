import { useId, useMemo, useRef, useState } from 'react'
import {
  KeyboardSensor,
  PointerSensor,
  TouchSensor,
  useSensor,
  useSensors,
} from '@dnd-kit/core'
import { t } from '../../i18n'
import type { GeneratorResult } from '../generator'
import type { Player, GameScore, CourtTime, SessionScoring } from '../types'
import { formatMergedCourtTimes } from '../utils/time'
import { formatLongDate } from '../../utils/day'
import { courtLabel } from '../utils/courtLabel'
import type { SwapTarget, TeamSwapTarget } from '../utils/swap'
import { validateChangeName } from '../utils/swap'
import type { SlotSwapTarget } from '../utils/slotSwap'
import ConfirmBars from './summary/ConfirmBars'
import ActionsMenu from './summary/ActionsMenu'
import ShareLinkPanel from './summary/ShareLinkPanel'
import PlayerStatsPanel from './summary/PlayerStatsPanel'
import ScheduleGrid, { type ScheduleGridScores } from './summary/ScheduleGrid'
import { useGridInteraction } from './summary/useGridInteraction'
import StandingsTab from './summary/StandingsTab'
import { useScoreDraft } from './summary/useScoreDraft'
import { useSummaryEditModes } from './summary/useSummaryEditModes'
import { useEscapeKey } from '../hooks/useEscapeKey'
import { useFocusTrap } from '../hooks/useFocusTrap'
import { Tabs } from '../../components/Tabs'
import { Spinner } from '../../components/Spinner'
import Icon from '../../components/Icon'

/** Read-only data props for SummaryModal */
interface SummaryModalBaseProps {
  result: GeneratorResult
  playerMap: Map<string, Player>
  slotsPerCourt: number[]
  courtNames: string[]
  playedGames: string[]
  gameScores: Record<string, GameScore>
  /** The session's frozen format; absent on a payload from an older build. */
  scoring?: SessionScoring
  title: string
  date: string
  sessionStart: string
  slotMinutes: number
  courtTimes: CourtTime[]
  standalone?: boolean
  locked?: boolean
  /** The viewer may read but not edit (e.g. a community member). */
  readOnly?: boolean
  absentPlayers?: string[]
  skippedPlayers?: Record<string, string[]>
  /** Cloud id; renders the share-link panel for a host/admin viewer. */
  shareSessionId?: string
}

/** Edit callback props for SummaryModal (all optional for read-only views) */
interface SummaryModalEditProps {
  onTogglePlayedGame?: (key: string) => void
  onSetGameScore?: (key: string, sets: { a: number; b: number }[]) => void | Promise<void>
  onSwapPlayers?: (t1: SwapTarget, t2: SwapTarget) => void
  onSetAbsent?: (nextAbsent: string[]) => void
  onSetGameSkipped?: (key: string, playerIds: string[]) => void | Promise<void>
  onReplacePlayer?: (playerId: string, newName: string) => void
  onSwapSlots?: (g1: SlotSwapTarget, g2: SlotSwapTarget) => void
  onSwapTeams?: (t1: TeamSwapTarget, t2: TeamSwapTarget) => void
  onChangePlayer?: (target: SwapTarget, newName: string) => void
  onRefetch?: () => void
  isRefetching?: boolean
  /** Approve and rate the session, or withdraw that approval. */
  onSetLocked?: (locked: boolean) => void | Promise<void>
  lockBusy?: boolean
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
  scoring,
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
  shareSessionId,
  onSetAbsent,
  onSetGameSkipped,
  onReplacePlayer,
  onSwapSlots,
  onSwapTeams,
  onChangePlayer,
  onRefetch,
  isRefetching = false,
  onSetLocked,
  lockBusy = false,
  onDelete,
  deleteLoading = false,
  locked = false,
  readOnly = false,
}: SummaryModalProps) {
  const played = new Set(playedArr)

  const [activeTab, setActiveTab] = useState<'schedule' | 'standings'>('schedule')
  // Escape closes the modal (not in standalone/full-page mode). The Actions
  // menu has its own handler; the stack in useEscapeKey guarantees one Escape
  // closes one thing, so no guard is needed here.
  useEscapeKey(() => {
    onClose?.()
  }, !!onClose && !standalone)

  const score = useScoreDraft(onSetGameScore, scoring)
  const { expandedScore, setExpandedScore, scoreError, setScoreError, draftScores, setDraftScores, updateDraftSet, handleScoreSave, handleClearScore, scoreFailures, retryScore, dismissScoreFailure } = score

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

  // Stable props for StandingsTab. Without them the useMemo inside it
  // recomputes computeStandings on every render, because arrays and objects
  // always have a new identity.
  const standingsPlayers = useMemo(() => [...playerMap.values()], [playerMap])
  const standingsAbsentIds = useMemo(() => [...effectiveAbsent], [effectiveAbsent])
  const standingsSkipped = useMemo(() => {
    const out: Record<string, string[]> = {}
    for (const [k, s] of Object.entries(effectiveSkipped)) out[k] = [...s]
    return out
  }, [effectiveSkipped])

  const [highlightedPlayerId, setHighlightedPlayerId] = useState<string | null>(null)
  const [deleteConfirm, setDeleteConfirm] = useState(false)
  const [lockConfirm, setLockConfirm] = useState(false)
  const dialogRef = useRef<HTMLDivElement>(null)
  const panelId = useId()
  const scheduleTabId = `${panelId}-schedule`
  const standingsTabId = `${panelId}-standings`
  type TabId = 'schedule' | 'standings'

  // Modal focus: move focus into the dialog, keep Tab inside it, and hand
  // focus back to the trigger when it closes. Full-page use is left alone.
  useFocusTrap(dialogRef, !standalone)

  const sensors = useSensors(
    useSensor(PointerSensor),
    useSensor(TouchSensor, { activationConstraint: { delay: 200, tolerance: 5 } }),
    // Keyboard alternative for slot swapping (drag is not the only way in).
    useSensor(KeyboardSensor),
  )

  // The grid takes its edit-mode channel and its score editor as one prop each.
  const gridInteraction = useGridInteraction({
    swapSelected,
    pendingSwap,
    teamSwapSelected,
    pendingTeamSwap,
    replaceTarget,
    changeTarget,
    sensors,
    onChipClick: handleChipClick,
    onTeamClick: handleTeamClick,
    onReplaceToggle: handleReplaceToggle,
    onChangeSelect: handleChangeSelect,
    onDragEnd: handleDragEnd,
  })

  const gridScores: ScheduleGridScores = {
    value: {
      expanded: expandedScore,
      drafts: draftScores,
      error: scoreError,
      failures: scoreFailures,
    },
    onChange: (change) => {
      switch (change.kind) {
        case 'expand':
          setExpandedScore(change.key)
          setScoreError(null)
          setDraftScores((prev) => ({ ...prev, [change.key]: change.draft }))
          break
        case 'collapse':
          setExpandedScore(null)
          setScoreError(null)
          break
        case 'set':
          updateDraftSet(change.key, change.index, change.side, change.value)
          break
        case 'save':
          handleScoreSave(change.key)
          break
        case 'clear':
          handleClearScore(change.key)
          break
        case 'retry':
          retryScore(change.key)
          break
        case 'dismiss':
          dismissScoreFailure(change.key)
          break
      }
    },
  }

  const totalGames = result.schedule.length
  const playedCount = played.size

  return (
    <div ref={dialogRef} tabIndex={-1} className={standalone ? 'flex-1 flex flex-col bg-ground overflow-hidden' : 'fixed inset-0 z-overlay bg-ground flex flex-col overflow-hidden'} role="dialog" aria-modal={!standalone} aria-label={t('summary.title')}>
      {/* Toolbar — wraps instead of clipping on a 390px screen. */}
      <div className="flex flex-wrap items-center justify-between gap-2 px-5 py-3 border-b border-slate-800 shrink-0">
        <div className="flex items-center gap-3 min-w-0">
          <Tabs
            items={[
              { id: 'schedule', label: t('summary.tab.schedule') },
              { id: 'standings', label: t('summary.tab.standings') },
            ]}
            value={activeTab}
            onChange={(id) => {
              setActiveTab(id as TabId)
              exitCurrentMode()
            }}
            panelId={panelId}
            label={t('summary.tabs')}
            tabClassName={(active) =>
              `inline-flex min-h-11 items-center text-xs font-semibold px-4 rounded-lg transition-colors ${
                active
                  ? 'bg-indigo-900/60 border border-indigo-700 text-indigo-300'
                  : 'text-slate-400 hover:text-slate-200'
              }`
            }
          />
          {playedCount > 0 && (
            <span className="text-xs text-slate-400">
              {t('summary.played', { played: playedCount, total: totalGames })}
            </span>
          )}
        </div>
        <div className="flex flex-wrap items-center justify-end gap-2 min-w-0">
          {locked && !onSetLocked && (
            <span className="text-xs font-semibold px-3 py-1.5 rounded-lg bg-amber-900/40 border border-amber-700 text-amber-400">
              🔒<span className="hidden sm:inline"> {t('summary.locked')}</span>
            </span>
          )}
          {/* Finishing is the rating gate, so it is never one careless click. */}
          {onSetLocked && !lockConfirm && (
            <button
              onClick={() => setLockConfirm(true)}
              disabled={lockBusy}
              className={`hit44 text-xs font-semibold px-3 py-1.5 rounded-lg border transition-colors disabled-dim ${
                locked
                  ? 'bg-slate-800 border-slate-600 text-slate-300 hover:text-white'
                  : 'bg-emerald-900/40 border-emerald-700 text-emerald-300 hover:bg-emerald-900/60'
              }`}
            >
              {locked ? t('summary.reopen') : t('summary.finish')}
            </button>
          )}
          {onSetLocked && lockConfirm && (
            <>
              <span className="text-xs text-slate-400 hidden sm:inline max-w-xs">
                {locked ? t('summary.reopenConfirm') : t('summary.finishConfirm')}
              </span>
              <button
                onClick={async () => {
                  setLockConfirm(false)
                  await onSetLocked(!locked)
                }}
                disabled={lockBusy}
                className={`hit44 text-xs font-bold px-3 py-1.5 rounded-lg text-white transition-colors disabled-dim ${
                  locked ? 'bg-amber-600 hover:bg-amber-500' : 'bg-emerald-600 hover:bg-emerald-500'
                }`}
              >
                {lockBusy
                  ? t('summary.saving')
                  : locked
                    ? t('summary.reopenYes')
                    : t('summary.finishYes')}
              </button>
              <button
                onClick={() => setLockConfirm(false)}
                aria-label={t('summary.cancel')}
                className="text-xs text-slate-400 hover:text-slate-200 px-2 py-1.5 rounded-lg border border-slate-700 bg-slate-800/60 transition-colors hit44"
              >
                ✕
              </button>
            </>
          )}
          {!locked && !readOnly && activeTab === 'schedule' && (onSwapPlayers || onSetAbsent || onSetGameSkipped || onReplacePlayer || onSwapSlots || onSwapTeams) && (
            mode !== 'idle' ? (
              <button
                onClick={() => { exitCurrentMode(); setActionsOpen(false) }}
                aria-label={t('summary.cancel')}
                className="text-xs font-semibold px-3 py-1.5 rounded-lg bg-slate-800 border border-slate-600 text-slate-300 hover:text-white transition-colors hit44"
              >
                ✕<span className="hidden sm:inline"> {t('summary.cancel')}</span>
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
          {shareSessionId && <ShareLinkPanel sessionId={shareSessionId} />}
          {/* Delete button */}
          {onDelete && !deleteConfirm && (
            <button
              onClick={() => setDeleteConfirm(true)}
              className="text-slate-400 hover:text-red-400 px-2 py-1.5 rounded-lg hover:bg-red-950/30 transition-colors text-sm hit44"
              aria-label={t('summary.delete')}
              title={t('summary.delete')}
            >
              <Icon name="trash" size={14} />
            </button>
          )}
          {onDelete && deleteConfirm && (
            <button
              onClick={() => { onDelete(); setDeleteConfirm(false) }}
              disabled={deleteLoading}
              className="text-xs font-bold px-3 py-1.5 rounded-lg bg-red-600 hover:bg-red-500 text-white transition-colors disabled-dim flex items-center gap-1.5 hit44"
            >
              {deleteLoading && <Spinner size={12} />}
              {deleteLoading ? t('summary.deleting') : t('summary.deleteConfirm')}
            </button>
          )}
          {deleteConfirm && (
            <button
              onClick={() => setDeleteConfirm(false)}
              aria-label={t('summary.deleteCancel')}
              className="text-xs text-slate-400 hover:text-slate-200 px-2 py-1.5 rounded-lg border border-slate-700 bg-slate-800/60 transition-colors hit44"
            >
              ✕
            </button>
          )}
          {/* Close button — only when onClose is provided */}
          {onClose && !deleteConfirm && (
            <button
              onClick={onClose}
              className="text-slate-400 hover:text-white px-3 py-1.5 rounded-lg hover:bg-slate-800 transition-colors text-sm hit44"
            >
              {t('summary.close')}
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
                {formatLongDate(date)}
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
              className="p-1.5 rounded-lg text-slate-400 hover:text-white hover:bg-slate-800 active:scale-90 transition-[color,transform] disabled-dim-faint shrink-0 hit44"
              aria-label={t('summary.reload')}
              aria-busy={isRefetching}
            >
              {isRefetching ? <Spinner size={16} /> : <Icon name="refresh" size={16} />}
            </button>
          )}
        </div>
      )}

      {/* Content */}
      <div id={panelId} role="tabpanel" aria-labelledby={activeTab === 'standings' ? standingsTabId : scheduleTabId} className={`flex-1 overflow-auto px-4 py-4 max-w-panel mx-auto w-full ${pendingSwap || absentChanged || skipChanged || pendingTeamSwap || pendingChange ? 'pb-24' : pendingSlotSwap ? 'pb-36' : ''}`}>
        {mode === 'swap' && !pendingSwap && (
          <div className="mb-3 rounded-lg bg-indigo-950/50 border border-indigo-800/40 px-3 py-2 flex flex-col gap-1">
            <span className="text-xs text-indigo-300 font-medium">
              {t(swapSelected ? 'summary.swapOne' : 'summary.swapStart')}
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
                ? t('summary.absentSome', { count: absentPending.size })
                : t('summary.absentNone')}
            </span>
            <span className="text-[11px] text-red-400/70">
              {t('summary.absentScope', { games: totalGames })}
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
                    className={`hit44 text-xs font-medium px-2 py-0.5 rounded-lg border transition-colors ${
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
                ? t('summary.skipSome', { count: flatSkippedCount })
                : t('summary.skipNone')}
            </span>
            <span className="text-[11px] text-amber-400/70">{t('summary.skipScope')}</span>
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
              <span className="text-xs text-emerald-300 font-medium">{t('summary.replacePrompt')}</span>
            ) : (
              <>
                <span className="text-xs text-emerald-300 font-medium">
                  {t('summary.replaceWith', { name: playerMap.get(replaceTarget)?.name ?? '' })}
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
                    placeholder={t('summary.namePlaceholder')}
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
                    className="text-xs font-bold px-3 py-1.5 rounded-lg bg-emerald-700 hover:bg-emerald-600 text-white transition-colors disabled-dim disabled:cursor-not-allowed shrink-0 flex items-center gap-1.5 hit44"
                  >
                    {saving && <Spinner size={12} />}
                    {saving ? 'Saving…' : '✓ Save'}
                  </button>
                </div>
              </>
            )}
          </div>
        )}
        {mode === 'slotSwap' && (
          <div className="mb-3 rounded-lg bg-amber-950/30 border border-amber-900/40 px-3 py-2">
            {slotSwapError ? (
              <span className="text-xs text-red-400">{slotSwapError}</span>
            ) : (
              <span className="text-xs text-amber-300 font-medium">{t('legacy.summaryModal.dragHint')}</span>
            )}
          </div>
        )}
        {mode === 'teamSwap' && (
          <div className="mb-3 rounded-lg bg-sky-950/30 border border-sky-900/40 px-3 py-2">
            {teamSwapError ? (
              <span className="text-xs text-red-400">{teamSwapError}</span>
            ) : (
              <span className="text-xs text-sky-300 font-medium">{t('legacy.summaryModal.teamSwapHint')}</span>
            )}
          </div>
        )}
        {mode === 'change' && (
          <div className="mb-3 rounded-lg bg-sky-950/30 border border-sky-900/40 px-3 py-2 flex flex-col gap-2">
            {changeTarget === null ? (
              <span className="text-xs text-sky-300 font-medium">{t('summary.changePrompt')}</span>
            ) : (
              <>
                <span className="text-xs text-sky-300 font-medium">
                  {t('legacy.summaryModal.changePrefix')}{' '}<strong>{playerMap.get(changeTarget.playerId)?.name ?? '?'}</strong>{' '}{t('legacy.summaryModal.changeSuffix', { slot: changeTarget.slot + 1, court: courtLabel(courtNames, changeTarget.court) })}</span>
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
                    placeholder={t('summary.namePlaceholder')}
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
                    className="text-xs font-bold px-3 py-1.5 rounded-lg bg-sky-700 hover:bg-sky-600 text-white transition-colors disabled-dim disabled:cursor-not-allowed shrink-0 hit44"
                  >
                    {t('summary.next')}
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
            playedGames={playedArr}
            absentPlayerIds={standingsAbsentIds}
            skippedPlayers={standingsSkipped}
          />
        ) : (
          <ScheduleGrid
            data={{
              result,
              slotsPerCourt,
              courtNames,
              sessionStart,
              slotMinutes,
              playerMap,
              playedGames: playedArr,
              gameScores,
              scoring,
              effectiveAbsent,
              effectiveSkipped,
              highlightedPlayerId,
            }}
            mode={mode}
            locked={locked || readOnly}
            saving={saving}
            scores={gridScores}
            interaction={gridInteraction}
            onTogglePlayedGame={onTogglePlayedGame}
            onSkipToggle={toggleSkipForGame}
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
