import { useMemo } from 'react'
import AnnotatedPlayerName from '../AnnotatedPlayerName'
import { HIGHLIGHTED_PLAYERS, TEAM_HIGHLIGHT_ENABLED } from '../../config/teamHighlights'
import { DndContext, type DragEndEvent } from '@dnd-kit/core'
import type { GeneratorResult } from '../../generator'
import type { Player, GameScore, SessionScoring } from '../../types'
import { toGameKey } from '../../types'
import { draftFromScore, type MatchDraft, type ScoreFailure } from './useScoreDraft'
import { describeSets, setsWon } from '../../utils/scoring'
import { computeBackToBackRunBySlot } from '../../utils/playerStats'
import { courtLabel } from '../../utils/courtLabel'
import { timeToMinutes, minutesToTime } from '../../utils/time'
import type { SwapTarget, TeamSwapTarget } from '../../utils/swap'
import type { PlayerChipMode } from './PlayerChipRenderer'
import PlayerChipRenderer from './PlayerChipRenderer'
import { hit44 } from '../hitTarget'
import SlotGameCard from './SlotGameCard'
import { t } from '@/i18n'

interface ScheduleGridProps {
  result: GeneratorResult
  slotsPerCourt: number[]
  courtNames: string[]
  sessionStart: string
  slotMinutes: number
  mode: PlayerChipMode
  locked: boolean
  saving: boolean
  playerMap: Map<string, Player>
  playedGames: string[]
  gameScores: Record<string, GameScore>
  scoring?: SessionScoring
  effectiveAbsent: Set<string>
  effectiveSkipped?: Record<string, Set<string>>
  expandedScore: string | null
  draftScores: Record<string, MatchDraft>
  scoreError: string | null
  scoreFailures?: Record<string, ScoreFailure>
  retryScore?: (key: string) => void
  dismissScoreFailure?: (key: string) => void
  // Swap state
  swapSelected: SwapTarget | null
  pendingSwap: { t1: SwapTarget; t2: SwapTarget } | null
  // Team swap state
  teamSwapSelected: TeamSwapTarget | null
  pendingTeamSwap: { t1: TeamSwapTarget; t2: TeamSwapTarget } | null
  // Replace state
  replaceTarget: string | null
  // Change state
  changeTarget: SwapTarget | null
  // DnD
  sensors: ReturnType<typeof import('@dnd-kit/core').useSensors>
  // Callbacks
  handleChipClick: (target: SwapTarget) => void
  handleTeamClick: (target: TeamSwapTarget) => void
  handleReplaceToggle: (playerId: string) => void
  handleChangeSelect: (target: SwapTarget) => void
  handleDragEnd: (event: DragEndEvent) => void
  handleScoreSave: (key: string) => void
  handleClearScore: (key: string) => void
  onTogglePlayedGame?: (key: string) => void
  onSkipToggle?: (gameKey: string, playerId: string) => void
  setExpandedScore: (key: string | null) => void
  setScoreError: (error: string | null) => void
  setDraftScores: (fn: (prev: Record<string, MatchDraft>) => Record<string, MatchDraft>) => void
  updateDraftSet: (key: string, index: number, side: 'a' | 'b', value: string) => void
  highlightedPlayerId?: string | null
}

export default function ScheduleGrid({
  result,
  slotsPerCourt,
  courtNames,
  sessionStart,
  slotMinutes,
  mode,
  locked,
  saving,
  playerMap,
  playedGames,
  gameScores,
  scoring,
  effectiveAbsent,
  effectiveSkipped = {},
  expandedScore,
  draftScores,
  scoreError,
  scoreFailures = {},
  retryScore,
  dismissScoreFailure,
  swapSelected,
  pendingSwap,
  teamSwapSelected,
  pendingTeamSwap,
  replaceTarget,
  changeTarget,
  sensors,
  handleChipClick,
  handleTeamClick,
  handleReplaceToggle,
  handleChangeSelect,
  handleDragEnd,
  handleScoreSave,
  handleClearScore,
  onTogglePlayedGame,
  onSkipToggle,
  setExpandedScore,
  setScoreError,
  setDraftScores,
  updateDraftSet,
  highlightedPlayerId,
}: ScheduleGridProps) {
  const played = useMemo(() => new Set(playedGames), [playedGames])

  const backToBackRunBySlot = useMemo(
    () => computeBackToBackRunBySlot(result.schedule, [...playerMap.keys()]),
    [result.schedule, playerMap],
  )

  const bySlot = new Map<number, typeof result.schedule>()
  for (const game of result.schedule) {
    const list = bySlot.get(game.slot) ?? []
    list.push(game)
    bySlot.set(game.slot, list)
  }

  const maxSlots = Math.max(
    Math.max(...slotsPerCourt),
    ...result.schedule.map(g => g.slot + 1)
  )

  function name(id: string): string {
    return playerMap.get(id)?.name ?? id
  }

  const scheduleGrid = (
    <div className="flex flex-col divide-y divide-slate-800">
      {Array.from({ length: maxSlots }, (_, s) => {
        const games = (bySlot.get(s) ?? []).sort((a, b) => a.court - b.court)
        return (
          <div key={s} className="flex items-start gap-4 py-4">
            <div className="flex flex-col items-center w-4 shrink-0 pt-0.5 gap-0.5">
              <span className="text-xs font-bold text-slate-400 tabular-nums">#{s + 1}</span>
              <span className="text-[11px] text-slate-400 font-medium leading-none tabular-nums">
                {minutesToTime(timeToMinutes(sessionStart) + s * slotMinutes)}
              </span>
            </div>
            <div className="flex flex-col gap-4 flex-1">
              {games.map((g) => {
                const key = toGameKey(s, g.court)
                const done = played.has(key)
                const savedScore = gameScores[key]
                const isOpen = expandedScore === key
                const draft = draftScores[key] ?? draftFromScore(savedScore, scoring)
                const savedSets = savedScore?.sets
                // Sets only decide the headline in a multi-set format. A
                // single-set session (legacy or first-to-30) must show the
                // points, or every game reads 1-0 / 0-1.
                const multiSet = !!scoring &&
                  (scoring.gamesToWin > 1 || (savedSets?.length ?? 0) > 1)
                const won = savedScore && savedSets && multiSet ? setsWon(savedSets) : null
                const headline = savedScore
                  ? (won ? `${won.a}–${won.b}` : `${savedScore.a}–${savedScore.b}`)
                  : ''
                const setLine = savedSets && savedSets.length > 1 ? describeSets(savedSets) : ''
                const teamANames = g.teamA.map((id) => playerMap.get(id)?.name ?? id).join(' & ')
                const teamBNames = g.teamB.map((id) => playerMap.get(id)?.name ?? id).join(' & ')

                // Satu render untuk team A/B (dulu blok kembar) — teamSwap pakai
                // tombol tim, mode lain pakai chip pemain.
                function teamCell(team: 'A' | 'B') {
                  const ids = team === 'A' ? g.teamA : g.teamB
                  if (mode === 'teamSwap') {
                    const tgt: TeamSwapTarget = { slot: s, court: g.court, team }
                    const teamIsSelected = teamSwapSelected?.slot === s && teamSwapSelected?.court === g.court && teamSwapSelected?.team === team
                    const teamIsPending = !!(pendingTeamSwap && (
                      (pendingTeamSwap.t1.slot === s && pendingTeamSwap.t1.court === g.court && pendingTeamSwap.t1.team === team) ||
                      (pendingTeamSwap.t2.slot === s && pendingTeamSwap.t2.court === g.court && pendingTeamSwap.t2.team === team)
                    ))
                    const teamIsDimmed = !!pendingTeamSwap && !teamIsPending
                    return (
                      <button
                        onClick={() => !pendingTeamSwap && handleTeamClick(tgt)}
                        disabled={!!pendingTeamSwap}
                        className={`hit44 flex items-center justify-center gap-1 min-w-0 min-h-6 px-1.5 py-0.5 rounded-lg border transition-colors ${
                          teamIsSelected ? 'border-amber-400 bg-amber-500/20' : 'bg-slate-800/40 border-slate-700 hover:border-sky-400'
                        } ${teamIsDimmed ? 'opacity-30' : ''}`}
                      >
                        {ids.map((id, i) => (
                          <span key={i} className="flex items-center gap-1">
                            {i > 0 && <span className="text-[10px] text-slate-400">&</span>}
                            <span className="text-xs font-medium text-slate-200"><AnnotatedPlayerName name={name(id)} /></span>
                          </span>
                        ))}
                      </button>
                    )
                  }
                  return (
                    <div className="flex items-center gap-1 min-w-0">
                      {([0, 1] as const).map((i) => {
                        const id = ids[i]
                        const n = name(id)
                        const chipSelected =
                          (swapSelected?.slot === s && swapSelected?.court === g.court && swapSelected?.playerId === id) ||
                          !!(pendingSwap && (
                            (pendingSwap.t1.slot === s && pendingSwap.t1.court === g.court && pendingSwap.t1.playerId === id) ||
                            (pendingSwap.t2.slot === s && pendingSwap.t2.court === g.court && pendingSwap.t2.playerId === id)
                          ))
                        const chipDimmed = !!pendingSwap && !chipSelected
                        return (
                          <span key={i} className={`flex items-center gap-1 min-w-0 ${chipDimmed ? 'opacity-30' : ''}`}>
                            {i > 0 && <span className="text-[10px] text-slate-400 shrink-0">&</span>}
                            <PlayerChipRenderer
                              playerName={n}
                              team={team}
                              position={i}
                              mode={mode}
                              done={done}
                              pendingSwap={pendingSwap}
                              isSelected={chipSelected}
                              isAbsent={effectiveAbsent.has(id)}
                              isSkipped={!!effectiveSkipped[toGameKey(s, g.court)]?.has(id)}
                              hasScore={!!gameScores[toGameKey(s, g.court)]}
                              replaceTarget={replaceTarget}
                              changeTarget={changeTarget}
                              onChipClick={handleChipClick}
                              onReplaceToggle={handleReplaceToggle}
                              onChangeSelect={handleChangeSelect}
                              onSkipToggle={onSkipToggle}
                              slot={s}
                              court={g.court}
                              playerId={id}
                              backToBackRun={backToBackRunBySlot[id]?.get(s)}
                            />
                          </span>
                        )
                      })}
                    </div>
                  )
                }

                const allPlayers = [...g.teamA, ...g.teamB] as string[]
                const isHighlighted = highlightedPlayerId ? allPlayers.includes(highlightedPlayerId) : false
                const isDimmed = highlightedPlayerId ? !isHighlighted : false
                const highlightedName = TEAM_HIGHLIGHT_ENABLED && highlightedPlayerId ? playerMap.get(highlightedPlayerId)?.name ?? null : null
                const highlightedTeam = highlightedName ? HIGHLIGHTED_PLAYERS[highlightedName] ?? null : null
                const glowClass = isHighlighted && highlightedTeam
                  ? (highlightedTeam === 'Green Grove' ? 'row-glow-g' : 'row-glow-b')
                  : ''

                const gameRow = (
                  <div className="flex flex-col gap-1">
                    {/* Game row header */}
                    <div
                      className={`flex items-center gap-2 select-none rounded-lg px-1 py-0.5 -mx-1 transition-colors ${
                        isHighlighted && TEAM_HIGHLIGHT_ENABLED && highlightedTeam === 'Green Grove' ? 'bg-emerald-400/8'
                        : isHighlighted && TEAM_HIGHLIGHT_ENABLED && highlightedTeam === 'Blue Waves' ? 'bg-sky-400/8'
                        : isHighlighted ? 'bg-yellow-400/10 ring-1 ring-yellow-400/40'
                        : done ? 'opacity-70'
                        : 'hover:bg-slate-800/40'
                      } ${isDimmed ? 'opacity-25' : ''} ${glowClass}`}
                    >
                      {/* Played toggle — 24px box with a 44px hit area so the team
                          columns keep their width at 402px */}
                      <button
                        type="button"
                        onClick={() => { if (!locked && !saving && mode === 'idle') onTogglePlayedGame?.(key) }}
                        disabled={locked || saving || mode !== 'idle' || !onTogglePlayedGame}
                        aria-pressed={done}
                        aria-label={`Played: ${teamANames} vs ${teamBNames}`}
                        className={`w-6 h-6 shrink-0 rounded border flex items-center justify-center transition-colors ${hit44} disabled:cursor-not-allowed ${locked || mode !== 'idle' ? 'opacity-25' : saving ? 'opacity-50' : 'cursor-pointer'} ${done ? 'bg-emerald-600 border-emerald-500' : 'border-slate-600 bg-slate-800'}`}
                      >
                        {done && <span className="text-white text-[10px] font-bold leading-none">✓</span>}
                      </button>
                      {/* Teams — 4-column precision grid: Court label (compact fixed), Team A, vs (centered lurus), Team B */}
                      <div
                        className="grid items-center gap-1 flex-1 min-w-0"
                        style={{ gridTemplateColumns: 'minmax(32px, 40px) 1fr 20px 1fr' }}
                      >
                        <span className="text-[10px] font-semibold text-slate-400 whitespace-nowrap">
                          {courtLabel(courtNames, g.court)}
                        </span>
                        {teamCell('A')}
                        <span className="text-slate-300 text-xs font-bold text-center select-none shrink-0">vs</span>
                        {teamCell('B')}
                      </div>
                      {/* Score toggle / saved score */}
                      {mode === 'idle' && (savedScore && !isOpen ? (
                        <button
                          onClick={() => { if (!locked) { setExpandedScore(key); setScoreError(null); setDraftScores((d) => ({ ...d, [key]: draftFromScore(savedScore, scoring) })) } }}
                          aria-label={`Score: ${teamANames} ${headline}${setLine ? `, sets ${setLine}` : ''}. Edit score`}
                          className={`text-[11px] font-bold shrink-0 whitespace-nowrap min-h-6 px-1 leading-tight tabular-nums ${hit44} ${locked ? 'text-slate-300 cursor-default' : 'text-emerald-300 hover:text-emerald-200'}`}
                        >
                          <span className="block">{headline}</span>
                          {setLine && <span className="block text-[11px] font-medium text-slate-400 tabular-nums">{setLine}</span>}
                        </button>
                      ) : !locked ? (
                        <button
                          onClick={() => {
                            if (isOpen) { setExpandedScore(null); setScoreError(null) }
                            else { setExpandedScore(key); setScoreError(null); setDraftScores((d) => ({ ...d, [key]: draftFromScore(undefined) })) }
                          }}
                          className={`text-[10px] text-slate-400 hover:text-slate-400 shrink-0 whitespace-nowrap min-h-6 px-1 transition-colors ${hit44}`}
                        >
                          {isOpen ? '▲ score' : '+ score'}
                        </button>
                      ) : null)}
                    </div>

                    {/* A failed score write stays attached to this game until
                        it is retried or dismissed. It is never timed out. */}
                    {scoreFailures[key] && (
                      <div
                        role="alert"
                        className="ml-6 flex flex-wrap items-center gap-2 rounded-lg border border-red-700/60 bg-red-900/20 px-2 py-1.5"
                      >
                        <span className="text-xs text-red-300">
                          {t('session.score.notSaved')} {scoreFailures[key].message}
                        </span>
                        <span className="ml-auto flex items-center gap-1">
                          <button
                            type="button"
                            onClick={() => retryScore?.(key)}
                            disabled={saving}
                            className="min-h-11 rounded-lg border border-red-500/70 px-2 text-xs font-bold text-red-200 transition-colors hover:bg-red-800/40 disabled:opacity-50"
                          >
                            {t('session.action.retry')}
                          </button>
                          <button
                            type="button"
                            onClick={() => dismissScoreFailure?.(key)}
                            className="min-h-11 rounded-lg px-2 text-xs text-red-300 underline underline-offset-2 transition-colors hover:text-red-100"
                            aria-label={t('session.score.dismiss', { teams: `${teamANames} vs ${teamBNames}` })}
                          >
                            {t('session.action.dismiss')}
                          </button>
                        </span>
                      </div>
                    )}

                    {/* Expandable score panel */}
                    {isOpen && (
                      <div className="ml-6 bg-slate-900 border border-indigo-800/60 rounded-lg px-3 py-2.5 flex flex-col gap-2">
                        {scoring && (
                          <p className="text-[10px] text-slate-400 text-center">
                            {scoring.label} · first to {scoring.gamesToWin} {scoring.gamesToWin === 1 ? 'set' : 'sets'} of {scoring.pointsToWin}
                          </p>
                        )}
                        <div className="flex flex-col gap-1.5">
                          {draft.map((row, index) => (
                            <div key={index} className="flex items-center justify-center gap-2">
                              <span className="w-10 text-right text-[10px] text-slate-400 tabular-nums">Set {index + 1}</span>
                              <input
                                type="number"
                                inputMode="numeric"
                                min={0}
                                max={99}
                                value={row.a}
                                onChange={(e) => updateDraftSet(key, index, 'a', e.target.value)}
                                className="w-14 bg-slate-800 border border-indigo-700 rounded-lg px-2 py-1.5 text-white font-bold text-lg text-center tabular-nums focus:outline-none focus:border-accent focus-visible:ring-2 focus-visible:ring-accent"
                                aria-label={`Set ${index + 1} score for ${teamANames}`}
                              />
                              <span className="text-slate-400 font-bold text-lg">–</span>
                              <input
                                type="number"
                                inputMode="numeric"
                                min={0}
                                max={99}
                                value={row.b}
                                onChange={(e) => updateDraftSet(key, index, 'b', e.target.value)}
                                className="w-14 bg-elevated border border-border rounded-lg px-2 py-1.5 text-slate-300 font-bold text-lg text-center tabular-nums focus:outline-none focus:border-accent focus-visible:ring-2 focus-visible:ring-accent"
                                aria-label={`Set ${index + 1} score for ${teamBNames}`}
                              />
                            </div>
                          ))}
                        </div>
                        <div className="flex flex-col items-center gap-1">
                          {scoreError && (
                            <p role="alert" className="text-[10px] text-red-400 text-center">{scoreError}</p>
                          )}
                          <div className="flex items-center gap-2">
                            {savedScore && (
                              <button
                                onClick={() => handleClearScore(key)}
                                disabled={saving}
                                className="px-3 py-1.5 min-h-6 rounded-lg border border-slate-600 text-slate-300 hover:text-white text-xs font-bold transition-colors disabled:opacity-50 disabled:cursor-not-allowed hit44"
                              >
                                {t('legacy.clear')}
                              </button>
                            )}
                            <button
                              onClick={() => handleScoreSave(key)}
                              disabled={saving}
                              className="px-6 py-1.5 min-h-6 rounded-lg bg-emerald-700 hover:bg-emerald-600 text-white text-xs font-bold transition-colors disabled:opacity-50 disabled:cursor-not-allowed flex items-center gap-1.5 hit44"
                            >
                              {saving && <svg className="animate-spin w-3 h-3 shrink-0" viewBox="0 0 24 24" fill="none"><circle className="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" strokeWidth="4" /><path className="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4z" /></svg>}
                              {saving ? 'Saving…' : '✓ Save'}
                            </button>
                          </div>
                        </div>
                      </div>
                    )}
                  </div>
                )
                return mode === 'slotSwap' ? (
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

  return mode === 'slotSwap' ? (
    <DndContext sensors={sensors} onDragEnd={handleDragEnd}>
      {scheduleGrid}
    </DndContext>
  ) : scheduleGrid
}
