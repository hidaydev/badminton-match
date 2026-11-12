import { useId, useState, useMemo } from 'react'
import AnnotatedPlayerName from '../AnnotatedPlayerName'
import type { Player, GameScore, ScheduleSlot } from '../../types'
import { computeStandings } from '../../utils/standings'
import { isPlaceholderName } from '../../utils/placeholders'
import { ordinal } from '../../utils/ordinal'
import { StandingsTable } from '../../../components/StandingsTable'
import PlayerMatchDetailSheet from './PlayerMatchDetailSheet'
import { t } from '../../../i18n'

// A stable object so the useMemo below stays valid on every render when the
// prop is empty.
const EMPTY_SKIPPED: Record<string, string[]> = {}

interface StandingsTabProps {
  players: Player[]
  schedule: ScheduleSlot[]
  gameScores: Record<string, GameScore>
  playedGames: string[]
  absentPlayerIds: string[]
  skippedPlayers?: Record<string, string[]>
  /** A guest reads the board: no row opens the match sheet. */
  interactive?: boolean
}

export default function StandingsTab({
  players,
  schedule,
  gameScores,
  playedGames,
  absentPlayerIds,
  skippedPlayers = EMPTY_SKIPPED,
  interactive = true,
}: StandingsTabProps) {
  const { absentList, placeholderList, voidPlayerIds, standings } = useMemo(() => {
    const absentList = players.filter(p => absentPlayerIds.includes(p.id))
    const placeholderList = players.filter(p => isPlaceholderName(p.name))
    // VOID = absent + placeholder (a game containing either is not tallied)
    const voidPlayerIds = [...absentPlayerIds, ...placeholderList.map(p => p.id)]
    const standings = computeStandings(
      players.filter(p => !absentPlayerIds.includes(p.id) && !isPlaceholderName(p.name)),
      schedule,
      gameScores,
      voidPlayerIds,
      skippedPlayers,
      playedGames,
    )
    return { absentList, placeholderList, voidPlayerIds, standings }
  }, [players, absentPlayerIds, schedule, gameScores, skippedPlayers, playedGames])

  const [selectedPlayer, setSelectedPlayer] = useState<{ standing: (typeof standings)[number]; rank: number } | null>(null)
  const hasScores = Object.keys(gameScores).length > 0
  const notPlayingId = useId()
  const notPlayingEmptyId = useId()

  if (!hasScores) {
    return (
      <div className="flex flex-col gap-4">
        <div className="flex items-center justify-center min-h-50">
          <p className="text-sm text-slate-400 text-center">{t('legacy.summaryStandings.empty')}</p>
        </div>
        {(absentList.length > 0 || placeholderList.length > 0) && (
          <div className="flex flex-col gap-1.5">
            <p className="text-[10px] font-bold text-slate-400 label-meta px-2" id={notPlayingEmptyId}>{t('legacy.summaryStandings.notPlaying')}</p>
            <ul role="list" aria-labelledby={notPlayingEmptyId} className="flex flex-col gap-1.5">
              {absentList.map(p => (
                <li key={p.id} className="flex items-center gap-2 pl-2 pr-2 py-2 rounded-xl border border-slate-800/50 bg-slate-800/20">
                  <span className="flex-1 text-sm font-medium text-slate-400 line-through">{p.name}</span>
                  <span className="text-[10px] text-slate-400">{t('session.absent')}</span>
                </li>
              ))}
              {placeholderList.map(p => (
                <li key={p.id} className="flex items-center gap-2 pl-2 pr-2 py-2 rounded-xl border border-slate-800/50 bg-slate-800/20">
                  <span className="flex-1 text-sm font-medium text-slate-400">{p.name}</span>
                  <span className="text-[10px] text-slate-400">{t('wizard.players.tbd')}</span>
                </li>
              ))}
            </ul>
          </div>
        )}
      </div>
    )
  }

  return (
    <div className="flex flex-col gap-1.5">
      {/* Tiebreaker order strip — hugs top divider */}
      <div className="flex justify-end gap-1 items-center pl-2 pr-2 -mt-4 pt-1 pb-3 text-[11px] text-slate-400">
        <span>{t('legacy.summaryStandings.rankedBy')}</span>
        <span className="font-semibold">{t('legacy.summaryStandings.wl')}</span>
        <span>›</span>
        <span className="font-semibold">{t('classic.column.diff')}</span>
        <span>›</span>
        <span className="font-semibold">{t('team.column.points')}</span>
        <span>›</span>
        <span className="font-semibold">{t('legacy.summaryStandings.az')}</span>
      </div>
      <StandingsTable
        rows={standings.map((s, i) => ({
          key: s.player.id,
          rank: ordinal(i + 1),
          name: <AnnotatedPlayerName name={s.player.name} />,
          wins: s.wins,
          losses: s.losses,
          diff: s.diff,
          pointsFor: s.pointsFor,
          onSelect: interactive ? () => setSelectedPlayer({ standing: s, rank: i + 1 }) : undefined,
        }))}
        labels={{ name: 'Name', winsLosses: 'W-L', diff: 'Diff', points: 'Pts' }}
      />
      {(absentList.length > 0 || placeholderList.length > 0) && (
        <>
          <div className="h-px bg-slate-800 my-1" />
          <p className="text-[10px] font-bold text-slate-400 label-meta px-2 mt-1" id={notPlayingId}>{t('legacy.summaryStandings.notPlaying')}</p>
          <ul role="list" aria-labelledby={notPlayingId} className="flex flex-col gap-1.5">
            {absentList.map(p => (
              <li key={p.id} className="flex items-center gap-2 pl-2 pr-2 py-2 rounded-xl border border-slate-800/50 bg-slate-800/20">
                <span className="flex-1 text-sm font-medium text-slate-400 line-through"><AnnotatedPlayerName name={p.name} /></span>
                <span className="text-[10px] text-slate-400">{t('session.absent')}</span>
              </li>
            ))}
            {placeholderList.map(p => (
              <li key={p.id} className="flex items-center gap-2 pl-2 pr-2 py-2 rounded-xl border border-slate-800/50 bg-slate-800/20">
                <span className="flex-1 text-sm font-medium text-slate-400"><AnnotatedPlayerName name={p.name} /></span>
                <span className="text-[10px] text-slate-400">{t('wizard.players.tbd')}</span>
              </li>
            ))}
          </ul>
        </>
      )}
      {interactive && (
        <PlayerMatchDetailSheet
          player={selectedPlayer?.standing ?? null}
          rank={selectedPlayer?.rank ?? 1}
          schedule={schedule}
          gameScores={gameScores}
          players={players}
          voidPlayerIds={voidPlayerIds}
          skippedPlayers={skippedPlayers}
          onClose={() => setSelectedPlayer(null)}
        />
      )}
    </div>
  )
}
