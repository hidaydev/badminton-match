import { useState } from 'react'
import { useSensors } from '@dnd-kit/core'
import { useGetSession } from '../queries'
import { selectSlotsPerCourt } from '../store/selectors'
import { collectAmbiguousBaseNames } from '../utils/nameParser'
import { AmbiguousNamesProvider, combineAmbiguous } from '../context/AmbiguousNamesContext'
import ScheduleGrid from '../components/summary/ScheduleGrid'
import PlayerStatsPanel from '../components/summary/PlayerStatsPanel'
import type { GeneratorResult } from '../generator'

const SESSION_ID = '1b6284b1f4b145bf'

const noop = () => {}

export default function SessionPreviewPage() {
  const { data: snapshot, isLoading, isError } = useGetSession(SESSION_ID)
  const sensors = useSensors()
  const [highlightedPlayerId, setHighlightedPlayerId] = useState<string | null>(null)

  if (isLoading) {
    return (
      <div className="min-h-screen bg-ground flex items-center justify-center text-slate-400 text-sm">
        Loading session…
      </div>
    )
  }

  if (isError || !snapshot) {
    return (
      <div className="min-h-screen bg-ground flex items-center justify-center text-slate-400 text-sm">
        Failed to load session.
      </div>
    )
  }

  const playerMap = new Map(snapshot.players.map((p) => [p.id, p]))
  const ambiguousNames = combineAmbiguous(
    new Set(),
    collectAmbiguousBaseNames(snapshot.players.map((p) => p.name)),
  )
  const result: GeneratorResult = {
    schedule: snapshot.schedule,
    playCount: {},
    sitCount: {},
    partnerWith: {},
    facedBy: {},
    unplacedFixMatches: [],
  }

  return (
    <AmbiguousNamesProvider value={ambiguousNames}>
      <div className="min-h-screen bg-ground text-fg p-4">
        <div className="mb-4 text-xs text-slate-500 font-mono">
          dev / session-preview · {SESSION_ID}
        </div>
        <ScheduleGrid
          result={result}
          slotsPerCourt={selectSlotsPerCourt(snapshot.session)}
          courtNames={snapshot.session.courtNames ?? []}
          sessionStart={snapshot.session.sessionStart}
          slotMinutes={snapshot.session.slotMinutes}
          mode="idle"
          locked={true}
          saving={false}
          playerMap={playerMap}
          playedGames={[]}
          gameScores={snapshot.gameScores ?? {}}
          effectiveAbsent={new Set(snapshot.absentPlayers ?? [])}
          effectiveSkipped={{}}
          expandedScore={null}
          draftScores={{}}
          scoreError={null}
          swapSelected={null}
          pendingSwap={null}
          teamSwapSelected={null}
          pendingTeamSwap={null}
          replaceTarget={null}
          changeTarget={null}
          sensors={sensors}
          handleChipClick={noop}
          handleTeamClick={noop}
          handleReplaceToggle={noop}
          handleChangeSelect={noop}
          handleDragEnd={noop}
          handleScoreSave={noop}
          setExpandedScore={noop}
          setScoreError={noop}
          setDraftScores={noop as never}
          highlightedPlayerId={highlightedPlayerId}
        />
        <PlayerStatsPanel
          schedule={snapshot.schedule}
          playerMap={playerMap}
          absentPlayers={snapshot.absentPlayers ?? []}
          standalone={true}
          highlightedPlayerId={highlightedPlayerId}
          onSelectPlayer={(id) => setHighlightedPlayerId((prev) => prev === id ? null : id)}
        />
      </div>
    </AmbiguousNamesProvider>
  )
}
