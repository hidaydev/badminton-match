import { useState, useMemo } from 'react'
import { useStore } from '../store'
import { timeToMinutes, timeToSlotIndex } from '../utils/time'
import { selectSlotsPerCourt, selectTotalGames } from '../store/selectors'
import { qualityScore as calcQualityScore, isGoodQuality } from '../utils/quality'
import { MAX_GENERATION_ATTEMPTS } from '../config/generator'
import { generate, type GeneratorResult, type GenerateContext } from '../generator'
import type { PlayerId } from '../types'
import { toPlayerId } from '../types'
import { useSharedView } from '../sharedView'
import ShareButton from '../components/ShareButton'
import SummaryModal from '../components/SummaryModal'
import { applySwap, applyTeamSwap, type SwapTarget, type TeamSwapTarget } from '../utils/swap'
import { applySlotSwap, type SlotSwapTarget } from '../utils/slotSwap'
import { ScheduleView, QualityBanner } from '../components/generate/ScheduleComponents'
import { useDebouncedPublish } from '../hooks/useDebouncedPublish'
import { isVersionMismatch } from '../queries/errors'
import { reloadPage } from '../utils/reload'
import { collectAmbiguousBaseNames } from '../utils/nameParser'
import { AmbiguousNamesProvider, combineAmbiguous, useAmbiguousNames } from '../context/AmbiguousNamesContext'
import { t } from '../../i18n'
import { Button } from '../../components/Button'
import { Toast } from '../../components/Toast'
import { ErrorText } from '../../components/ErrorText'

export default function GeneratePage() {
  const { isSharedView, snapshot, exitSharedView } = useSharedView()

  const storePlayers = useStore((s) => s.players)
  const storeFixMatches = useStore((s) => s.fixMatches)
  const storeSession = useStore((s) => s.session)
  const storeResult = useStore((s) => s.lastResult)
  const setStoreResult = useStore((s) => s.setResult)
  const updateSchedule = useStore((s) => s.updateSchedule)
  const swapSlotsWithScores = useStore((s) => s.swapSlotsWithScores)
  const updateRosterPlayer = useStore((s) => s.updatePlayer)

  const players = useMemo(
    () => (isSharedView ? (snapshot?.players ?? []) : storePlayers),
    [isSharedView, snapshot, storePlayers],
  )
  const fixMatches = useMemo(
    () => (isSharedView ? [] : storeFixMatches),
    [isSharedView, storeFixMatches],
  )
  const session = useMemo(
    () => (isSharedView ? (snapshot?.session ?? storeSession) : storeSession),
    [isSharedView, snapshot, storeSession],
  )

  const [showSummary, setShowSummary] = useState(false)
  const playedArr = useStore((s) => s.playedGames)
  const gameScores = useStore((s) => s.gameScores)
  const togglePlayedGame = useStore((s) => s.togglePlayedGame)
  const setGameScore = useStore((s) => s.setGameScore)
  const cloudSessionId = useStore((s) => s.cloudSessionId)
  const absentPlayers = useStore((s) => s.absentPlayers)
  const setAbsentPlayers = useStore((s) => s.setAbsentPlayers)
  // Normal flow reads lastResult from the store as the single source of truth.
  // Shared view is read-only against the server, but its edit handlers may still
  // adjust the locally-displayed schedule; those tweaks are ephemeral (never
  // published) and held in this override rather than duplicated store state.
  const [sharedResult, setSharedResult] = useState<GeneratorResult | null>(
    isSharedView ? (snapshot?.lastResult ?? null) : null
  )
  const result = isSharedView ? (sharedResult ?? snapshot?.lastResult ?? null) : storeResult
  const [error, setError] = useState<string | null>(null)
  const [saveError, setSaveError] = useState<{ message: string; stale: boolean } | null>(null)
  const [retryInfo, setRetryInfo] = useState<{ attempts: number; perfect: boolean } | null>(null)
  const [isGenerating, setIsGenerating] = useState(false)

  // The publish and score errors below are not success acknowledgements, so
  // they stay on screen until the user retries or dismisses them.

  // Derivasi stabil: map pemain & layout court dihitung ulang hanya saat input berubah.
  const playerMap = useMemo(() => new Map(players.map((p) => [p.id, p])), [players])
  // Ambiguous base names (appearing more than once), so only those show the (i)
  // badge. Unioned with the global (population) set: a name that is ambiguous in
  // the population keeps its badge even when it appears once in this session.
  const globalAmbiguous = useAmbiguousNames()
  const ambiguousNames = useMemo(
    () => combineAmbiguous(globalAmbiguous, collectAmbiguousBaseNames(players.map((p) => p.name))),
    [globalAmbiguous, players],
  )
  const slotsPerCourt = useMemo(() => selectSlotsPerCourt(session), [session])

  const { publishToCloud, isSaving } = useDebouncedPublish(
    cloudSessionId,
    (msg, err) => setSaveError({ message: msg, stale: isVersionMismatch(err) }),
    () => setSaveError(null),
  )

  // A shared link is a spectator view: the snapshot it decoded is the only
  // owner of the session, so an edit must never reach the draft store (another
  // community's draft could be sitting there) nor the publish queue.
  function handleTogglePlayed(key: string) {
    if (isSharedView) return
    togglePlayedGame(key)
    publishToCloud()
  }

  function handleSetScore(key: string, sets: { a: number; b: number }[]) {
    if (isSharedView) return
    setGameScore(key, sets)
    publishToCloud()
  }

  function handleSwapPlayers(t1: SwapTarget, t2: SwapTarget) {
    if (!result) return
    const newSchedule = applySwap(result.schedule, t1, t2)
    if (isSharedView) {
      setSharedResult({ ...result, schedule: newSchedule })
      return
    }
    updateSchedule(newSchedule)
    publishToCloud()
  }

  function handleSwapTeams(t1: TeamSwapTarget, t2: TeamSwapTarget) {
    if (!result) return
    const newSchedule = applyTeamSwap(result.schedule, t1, t2)
    if (isSharedView) {
      setSharedResult({ ...result, schedule: newSchedule })
      return
    }
    updateSchedule(newSchedule)
    publishToCloud()
  }

  function handleSwapSlots(g1: SlotSwapTarget, g2: SlotSwapTarget) {
    if (!result) return
    if (isSharedView) {
      setSharedResult({ ...result, schedule: applySlotSwap(result.schedule, g1, g2) })
      return
    }
    swapSlotsWithScores(g1, g2)
    publishToCloud()
  }

  function handleReplacePlayer(playerId: string, newName: string) {
    if (!result) return
    const pid = toPlayerId(playerId)
    const name = newName.trim()
    let nextId = toPlayerId(name)
    if (!isSharedView && name !== '') {
      const existing = storePlayers.find(
        (player) => player.name.trim().toLowerCase() === name.toLowerCase(),
      )
      if (existing !== undefined) {
        nextId = existing.id
      } else {
        // Publish resolves names through `players`; a name that only exists in
        // the schedule would be sent raw and rejected as an unknown player.
        // The slot keeps its id, so the roster entry is renamed in place.
        updateRosterPlayer(pid, { name })
        nextId = pid
      }
    }
    const newSchedule = result.schedule.map(slot => ({
      ...slot,
      teamA: slot.teamA.map(id => id === pid ? nextId : id) as [PlayerId, PlayerId],
      teamB: slot.teamB.map(id => id === pid ? nextId : id) as [PlayerId, PlayerId],
    }))
    if (isSharedView) {
      setSharedResult({ ...result, schedule: newSchedule })
      return
    }
    updateSchedule(newSchedule)
    publishToCloud()
  }

  function handleSetAbsent(nextAbsent: string[]) {
    if (isSharedView) return
    setAbsentPlayers(nextAbsent)
    publishToCloud()
  }

  function buildOffsets() {
    return session.courtTimes.map((ct) =>
      Math.floor((timeToMinutes(ct.start) - timeToMinutes(session.sessionStart)) / session.slotMinutes)
    )
  }

  function validatePlayers() {
    if (players.length < 4) return 'Need at least 4 players.'
    if (players.length < slotsPerCourt.length * 4)
      return `Need at least ${slotsPerCourt.length * 4} players for ${slotsPerCourt.length} courts.`
    return null
  }

  function qualityScore(r: GeneratorResult) {
    return calcQualityScore(r, playerMap, fixMatches)
  }

  function isGood(r: GeneratorResult) {
    return isGoodQuality(r, playerMap, fixMatches)
  }

  async function handleRetryUntilGood() {
    if (isGenerating) return
    setError(null)
    const err = validatePlayers()
    if (err) { setError(err); return }
    setIsGenerating(true)
    try {
      const offsets = buildOffsets()
      const ctx: GenerateContext = {
        players,
        slotsPerCourt: slotsPerCourt,
        fixMatches,
        courtOffsets: offsets,
        timeToSlotIndex: (time) => timeToSlotIndex(session, time),
      }
      let best = generate(ctx)
      let attempts = 1
      while (attempts < MAX_GENERATION_ATTEMPTS && !isGood(best)) {
        await new Promise<void>(r => requestAnimationFrame(() => r()))
        const candidate = generate(ctx)
        if (qualityScore(candidate) < qualityScore(best)) best = candidate
        attempts++
        if (isGood(best)) break
      }
      setStoreResult(best)
      setRetryInfo({ attempts, perfect: isGood(best) })
    } catch (e) {
      setError(String(e))
    } finally {
      setIsGenerating(false)
    }
  }

  return (
    <AmbiguousNamesProvider value={ambiguousNames}>
    <div className="flex flex-col gap-6">
      {isSharedView && (
        <div className="flex items-center justify-between gap-3 px-3 py-2.5 rounded-xl bg-indigo-900/30 border border-indigo-800 text-sm">
          <span className="text-indigo-300">Viewing a shared schedule</span>
          <Button variant="ghost" size="sm" onClick={exitSharedView} className="shrink-0">
            {t('legacy.startOwnSession')}
          </Button>
        </div>
      )}

      <div className="flex flex-wrap items-start justify-between gap-2">
        <div>
          <div className="flex items-center gap-2 mb-0.5">
            <h1 className="text-lg font-bold text-fg">Generate Schedule</h1>
          </div>
          <p className="text-slate-400 text-xs sm:text-sm">
            {players.length} players · {selectTotalGames(session)} games · {session.courts} court{session.courts > 1 ? 's' : ''}
          </p>
        </div>
        {result && (
          <div className="flex gap-1.5 shrink-0">
            <Button
              variant="secondary"
              size="sm"
              onClick={() => setShowSummary(true)}
              className="whitespace-nowrap"
            >
              {t('legacy.summary')}
            </Button>
            {!isSharedView && (
              <>
                {!cloudSessionId && (
                  <Button
                    variant="secondary"
                    size="sm"
                    loading={isGenerating}
                    onClick={handleRetryUntilGood}
                    className="whitespace-nowrap"
                  >
                    ↺ Regenerate
                  </Button>
                )}
                <ShareButton />
              </>
            )}
          </div>
        )}
      </div>

      {error && (
        <div className="p-3 bg-red-900/30 border border-red-700 rounded-xl text-red-400 text-sm">
          <ErrorText inherit>{error}</ErrorText>
        </div>
      )}
      {saveError && (
        <Toast
          message={saveError.message}
          action={
            saveError.stale ? (
              // A stale conditional request cannot succeed by resending it.
              // The safe action is to load the server's current state.
              <Button variant="danger" size="sm" className="font-bold" onClick={() => reloadPage()}>
                {t('session.action.reload')}
              </Button>
            ) : (
              <Button
                variant="danger"
                size="sm"
                className="font-bold"
                onClick={() => { setSaveError(null); publishToCloud() }}
              >
                {t('session.action.retry')}
              </Button>
            )
          }
          onDismiss={() => setSaveError(null)}
        />
      )}

      {result && result.unplacedFixMatches.length > 0 && (
        <div className="p-3 bg-amber-900/30 border border-amber-700 rounded-xl text-amber-400 text-sm flex flex-col gap-1.5">
          <span className="font-medium">⚠ {result.unplacedFixMatches.length} fix match{result.unplacedFixMatches.length > 1 ? 'es' : ''} could not be placed:</span>
          {result.unplacedFixMatches.map((id) => {
            const fm = fixMatches.find((m) => m.id === id)
            if (!fm) return null
            const name = (pid: string) => playerMap.get(toPlayerId(pid))?.name ?? '?'
            const [a1, a2, b1, b2] = fm.slots
            const side = (ids: string[]) => ids.filter(Boolean).map(name).join(' + ') || 'anyone'
            const desc = (a1 || a2) && (b1 || b2)
              ? `${side([a1, a2])} vs ${side([b1, b2])}`
              : `${side([a1, a2, b1, b2].filter(Boolean))} paired together`
            return <span key={id} className="text-xs text-amber-300 pl-3">· {desc}</span>
          })}
        </div>
      )}

      {result && (
        <>
          <QualityBanner result={result} playerMap={playerMap} fixMatches={fixMatches} onRetryUntilGood={isSharedView || cloudSessionId ? undefined : handleRetryUntilGood} retryInfo={retryInfo} />
        </>
      )}

      {!result ? (
        <Button
          className="w-full font-bold"
          loading={isGenerating}
          onClick={handleRetryUntilGood}
          disabled={players.length < 4}
        >
          ▶ Generate Schedule
        </Button>
      ) : (
        <ScheduleView
          result={result}
          playerMap={playerMap}
          slotsPerCourt={slotsPerCourt}
          courtNames={session.courtNames ?? []}
        />
      )}

      {showSummary && result && (
        <SummaryModal
          result={result}
          playerMap={playerMap}
          slotsPerCourt={slotsPerCourt}
          courtNames={session.courtNames ?? []}
          playedGames={playedArr}
          gameScores={gameScores}
          scoring={session.scoring}
          onTogglePlayedGame={handleTogglePlayed}
          onSetGameScore={handleSetScore}
          readOnly={isSharedView}
          onClose={() => setShowSummary(false)}
          title={session.title}
          date={session.date}
          sessionStart={session.sessionStart}
          slotMinutes={session.slotMinutes}
          courtTimes={session.courtTimes}
          saving={isSaving}
          onSwapPlayers={handleSwapPlayers}
          onSwapTeams={handleSwapTeams}
          onSwapSlots={handleSwapSlots}
          onReplacePlayer={handleReplacePlayer}
          onSetAbsent={cloudSessionId ? handleSetAbsent : undefined}
          absentPlayers={absentPlayers}
          shareSessionId={cloudSessionId && !isSharedView ? cloudSessionId : undefined}
        />
      )}
    </div>
    </AmbiguousNamesProvider>
  )
}
