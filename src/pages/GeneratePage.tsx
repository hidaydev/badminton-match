import { useState, useEffect } from 'react'
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

export default function GeneratePage() {
  const { isSharedView, snapshot, exitSharedView } = useSharedView()

  const storePlayers = useStore((s) => s.players)
  const storeFixMatches = useStore((s) => s.fixMatches)
  const storeSession = useStore((s) => s.session)
  const storeResult = useStore((s) => s.lastResult)
  const setStoreResult = useStore((s) => s.setResult)
  const updateSchedule = useStore((s) => s.updateSchedule)
  const swapSlotsWithScores = useStore((s) => s.swapSlotsWithScores)

  const players = isSharedView ? (snapshot?.players ?? []) : storePlayers
  const fixMatches = isSharedView ? [] : storeFixMatches
  const session = isSharedView ? (snapshot?.session ?? storeSession) : storeSession

  const [showSummary, setShowSummary] = useState(false)
  const playedArr = useStore((s) => s.playedGames)
  const gameScores = useStore((s) => s.gameScores)
  const togglePlayedGame = useStore((s) => s.togglePlayedGame)
  const setGameScore = useStore((s) => s.setGameScore)
  const cloudSessionId = useStore((s) => s.cloudSessionId)
  const absentPlayers = useStore((s) => s.absentPlayers)
  const setAbsentPlayers = useStore((s) => s.setAbsentPlayers)
  const [result, setResult] = useState<GeneratorResult | null>(
    isSharedView ? (snapshot?.lastResult ?? null) : storeResult
  )
  const [error, setError] = useState<string | null>(null)
  const [saveError, setSaveError] = useState<string | null>(null)
  const [retryInfo, setRetryInfo] = useState<{ attempts: number; perfect: boolean } | null>(null)
  const [isGenerating, setIsGenerating] = useState(false)

  // Auto-dismiss error toast after 5 seconds
  useEffect(() => {
    if (!saveError) return
    const timer = setTimeout(() => setSaveError(null), 5000)
    return () => clearTimeout(timer)
  }, [saveError])

  const playerMap = new Map(players.map((p) => [p.id, p]))

  const { publishToCloud, isSaving } = useDebouncedPublish(cloudSessionId, (msg) => setSaveError(msg))

  function handleTogglePlayed(key: string) {
    togglePlayedGame(key)
    publishToCloud()
  }

  function handleSetScore(key: string, a: number, b: number) {
    setGameScore(key, a, b)
    publishToCloud()
  }

  function handleSwapPlayers(t1: SwapTarget, t2: SwapTarget) {
    if (!result) return
    const newSchedule = applySwap(result.schedule, t1, t2)
    updateSchedule(newSchedule)
    setResult({ ...result, schedule: newSchedule })
    publishToCloud()
  }

  function handleSwapTeams(t1: TeamSwapTarget, t2: TeamSwapTarget) {
    if (!result) return
    const newSchedule = applyTeamSwap(result.schedule, t1, t2)
    updateSchedule(newSchedule)
    setResult({ ...result, schedule: newSchedule })
    publishToCloud()
  }

  function handleSwapSlots(g1: SlotSwapTarget, g2: SlotSwapTarget) {
    if (!result) return
    swapSlotsWithScores(g1, g2)
    setResult((prev) => prev ? { ...prev, schedule: applySlotSwap(prev.schedule, g1, g2) } : prev)
    publishToCloud()
  }

  function handleReplacePlayer(playerId: string, newName: string) {
    if (!result) return
    const pid = toPlayerId(playerId)
    const newNameId = toPlayerId(newName)
    const newSchedule = result.schedule.map(slot => ({
      ...slot,
      teamA: slot.teamA.map(id => id === pid ? newNameId : id) as [PlayerId, PlayerId],
      teamB: slot.teamB.map(id => id === pid ? newNameId : id) as [PlayerId, PlayerId],
    }))
    updateSchedule(newSchedule)
    setResult({ ...result, schedule: newSchedule })
    publishToCloud()
  }

  function handleSetAbsent(nextAbsent: string[]) {
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
    if (players.length < selectSlotsPerCourt(session).length * 4)
      return `Need at least ${selectSlotsPerCourt(session).length * 4} players for ${selectSlotsPerCourt(session).length} courts.`
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
        slotsPerCourt: selectSlotsPerCourt(session),
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
      setResult(best)
      setStoreResult(best)
      setRetryInfo({ attempts, perfect: isGood(best) })
    } catch (e) {
      setError(String(e))
    } finally {
      setIsGenerating(false)
    }
  }

  return (
    <div className="flex flex-col gap-6">
      {isSharedView && (
        <div className="flex items-center justify-between gap-3 px-3 py-2.5 rounded-xl bg-indigo-900/30 border border-indigo-800 text-sm">
          <span className="text-indigo-300">Viewing a shared schedule</span>
          <button
            onClick={exitSharedView}
            className="text-xs text-indigo-400 hover:text-white underline underline-offset-2 shrink-0 transition-colors"
          >
            Start your own session
          </button>
        </div>
      )}

      <div className="flex flex-wrap items-start justify-between gap-2">
        <div>
          <div className="flex items-center gap-2 mb-0.5">
            <h2 className="text-lg font-bold text-fg">Generate Schedule</h2>
          </div>
          <p className="text-slate-400 text-xs sm:text-sm">
            {players.length} players · {selectTotalGames(session)} games · {session.courts} court{session.courts > 1 ? 's' : ''}
          </p>
        </div>
        {result && (
          <div className="flex gap-1.5 shrink-0">
            <button
              onClick={() => setShowSummary(true)}
              className="text-xs text-indigo-300 hover:text-white px-2.5 py-1.5 rounded-lg bg-indigo-900/50 hover:bg-indigo-800 border border-indigo-700 transition-colors whitespace-nowrap"
            >
              Summary
            </button>
            {!isSharedView && (
              <>
                {!cloudSessionId && (
                  <button
                    onClick={handleRetryUntilGood}
                    disabled={isGenerating}
                    className="text-xs text-emerald-400 hover:text-emerald-200 disabled:opacity-40 disabled:cursor-not-allowed px-2.5 py-1.5 rounded-lg bg-emerald-900/30 hover:bg-emerald-900/50 border border-emerald-800 transition-colors whitespace-nowrap"
                  >
                    {isGenerating ? '⏳ Generating…' : '↺ Regenerate'}
                  </button>
                )}
                <ShareButton />
              </>
            )}
          </div>
        )}
      </div>

      {error && (
        <div className="p-3 bg-red-900/30 border border-red-700 rounded-xl text-red-400 text-sm" role="alert" aria-live="polite">
          {error}
        </div>
      )}
      {saveError && (
        <div className="p-3 bg-red-900/30 border border-red-700 rounded-xl text-red-400 text-sm" role="alert" aria-live="polite">
          {saveError}
        </div>
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
        <button
          onClick={handleRetryUntilGood}
          disabled={players.length < 4 || isGenerating}
          className="w-full py-2.5 bg-indigo-400 hover:bg-indigo-300 disabled:opacity-40 disabled:cursor-not-allowed text-slate-950 font-bold text-sm rounded-lg transition-colors"
        >
          {isGenerating ? '⏳ Generating…' : '▶ Generate Schedule'}
        </button>
      ) : (
        <ScheduleView
          result={result}
          playerMap={playerMap}
          slotsPerCourt={selectSlotsPerCourt(session)}
          courtNames={session.courtNames ?? []}
        />
      )}

      {showSummary && result && (
        <SummaryModal
          result={result}
          playerMap={playerMap}
          slotsPerCourt={selectSlotsPerCourt(session)}
          courtNames={session.courtNames ?? []}
          playedGames={playedArr}
          gameScores={gameScores}
          onTogglePlayedGame={handleTogglePlayed}
          onSetGameScore={handleSetScore}
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
          onSetAbsent={handleSetAbsent}
          absentPlayers={absentPlayers}
        />
      )}
    </div>
  )
}
