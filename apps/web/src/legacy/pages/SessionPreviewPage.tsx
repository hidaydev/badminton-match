import { useState } from 'react'
import { useGetSession } from '../queries'
import { selectSlotsPerCourt } from '../store/selectors'
import { collectAmbiguousBaseNames } from '../utils/nameParser'
import { AmbiguousNamesProvider, combineAmbiguous } from '../context/AmbiguousNamesContext'
import ScheduleGrid from '../components/summary/ScheduleGrid'
import PlayerStatsPanel from '../components/summary/PlayerStatsPanel'
import type { GeneratorResult } from '../generator'
import { t } from '../../i18n'

const SESSION_ID = '1b6284b1f4b145bf'

export default function SessionPreviewPage() {
  const { data: snapshot, isLoading, isError } = useGetSession(SESSION_ID)
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
        {t('legacy.failedToLoadSession')}
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
          data={{
            result,
            slotsPerCourt: selectSlotsPerCourt(snapshot.session),
            courtNames: snapshot.session.courtNames ?? [],
            sessionStart: snapshot.session.sessionStart,
            slotMinutes: snapshot.session.slotMinutes,
            playerMap,
            playedGames: [],
            gameScores: snapshot.gameScores ?? {},
            scoring: snapshot.session.scoring,
            effectiveAbsent: new Set(snapshot.absentPlayers ?? []),
            effectiveSkipped: {},
            highlightedPlayerId,
          }}
          mode="idle"
          locked={true}
          saving={false}
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
