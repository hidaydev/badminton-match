import { DndContext, type DragEndEvent } from '@dnd-kit/core'
import type { GeneratorResult } from '../../generator'
import type { Player, GameScore } from '../../types'
import { toGameKey } from '../../types'
import { computeBackToBackRuns } from '../../utils/playerStats'
import { timeToMinutes, minutesToTime } from '../../utils/time'
import type { SwapTarget, TeamSwapTarget, ChangeTarget } from '../../utils/swap'
import type { PlayerChipMode } from './PlayerChipRenderer'
import PlayerChipRenderer from './PlayerChipRenderer'
import SlotGameCard from './SlotGameCard'

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
  effectiveAbsent: Set<string>
  effectiveSkipped?: Record<string, Set<string>>
  expandedScore: string | null
  draftScores: Record<string, { a: string; b: string }>
  scoreError: string | null
  // Swap state
  swapSelected: SwapTarget | null
  pendingSwap: { t1: SwapTarget; t2: SwapTarget } | null
  // Team swap state
  teamSwapSelected: TeamSwapTarget | null
  pendingTeamSwap: { t1: TeamSwapTarget; t2: TeamSwapTarget } | null
  // Replace state
  replaceTarget: string | null
  // Change state
  changeTarget: ChangeTarget | null
  // DnD
  sensors: ReturnType<typeof import('@dnd-kit/core').useSensors>
  // Callbacks
  handleChipClick: (target: SwapTarget) => void
  handleTeamClick: (target: TeamSwapTarget) => void
  handleReplaceToggle: (playerId: string) => void
  handleChangeSelect: (target: ChangeTarget) => void
  handleDragEnd: (event: DragEndEvent) => void
  handleScoreSave: (key: string) => void
  onTogglePlayedGame?: (key: string) => void
  onSkipToggle?: (gameKey: string, playerId: string) => void
  setExpandedScore: (key: string | null) => void
  setScoreError: (error: string | null) => void
  setDraftScores: (fn: (prev: Record<string, { a: string; b: string }>) => Record<string, { a: string; b: string }>) => void
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
  effectiveAbsent,
  effectiveSkipped = {},
  expandedScore,
  draftScores,
  scoreError,
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
  onTogglePlayedGame,
  onSkipToggle,
  setExpandedScore,
  setScoreError,
  setDraftScores,
}: ScheduleGridProps) {
  const played = new Set(playedGames)

  const backToBackRuns = new Map(Object.entries(computeBackToBackRuns(result.schedule, [...playerMap.keys()])))

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

  function courtLabel(courtIndex: number): string {
    return courtNames[courtIndex] ?? `C${courtIndex + 1}`
  }

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
              <span className="text-xs font-bold text-slate-400">#{s + 1}</span>
              <span className="text-[8px] text-slate-400 font-medium leading-none">
                {minutesToTime(timeToMinutes(sessionStart) + s * slotMinutes)}
              </span>
            </div>
            <div className="flex flex-col gap-2.5 flex-1">
              {games.map((g) => {
                const key = toGameKey(s, g.court)
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
                        className={`w-4 h-4 shrink-0 rounded border flex items-center justify-center transition-colors ${locked || mode !== 'idle' ? 'cursor-not-allowed opacity-25' : saving ? 'cursor-not-allowed opacity-50' : 'cursor-pointer'} ${done ? 'bg-emerald-600 border-emerald-500' : 'border-slate-600 bg-slate-800'}`}
                        onClick={() => { if (!locked && !saving && mode === 'idle') onTogglePlayedGame?.(key) }}
                      >
                        {done && <span className="text-white text-[10px] font-bold leading-none">✓</span>}
                      </div>
                      {/* Teams */}
                      <div className="grid items-center gap-2 flex-1 min-w-0" style={{ gridTemplateColumns: 'auto 1fr auto 1fr' }}>
                        <span className="text-[10px] font-semibold text-slate-400 whitespace-nowrap">
                          {courtLabel(g.court)}
                        </span>
                        {mode === 'teamSwap' ? (
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
                                    {i > 0 && <span className="text-[10px] text-slate-400">&</span>}
                                    <span className="text-xs font-medium text-slate-200">{name(id)}</span>
                                  </span>
                                ))}
                              </button>
                            )
                          })()
                        ) : (
                          <div className="flex items-center gap-1 min-w-0">
                            {([0, 1] as const).map((i) => {
                              const id = g.teamA[i]
                              const n = name(id)
                              const isSelected =
                                (swapSelected?.slot === s && swapSelected?.court === g.court && swapSelected?.playerId === id) ||
                                !!(pendingSwap && (
                                  (pendingSwap.t1.slot === s && pendingSwap.t1.court === g.court && pendingSwap.t1.playerId === id) ||
                                  (pendingSwap.t2.slot === s && pendingSwap.t2.court === g.court && pendingSwap.t2.playerId === id)
                                ))
                              const isDimmed = !!pendingSwap && !isSelected
                              return (
                                <span key={i} className={`flex items-center gap-1 ${isDimmed ? 'opacity-30' : ''}`}>
                                  {i > 0 && <span className="text-[10px] text-slate-400">&</span>}
                                  <PlayerChipRenderer
                                    playerName={n}
                                    team="A"
                                    position={i}
                                    mode={mode}
                                    done={done}
                                    pendingSwap={pendingSwap}
                                    isSelected={isSelected}
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
                                    backToBackRuns={backToBackRuns.get(id)}
                                  />
                                </span>
                              )
                            })}
                          </div>
                        )}
                        <span className="text-slate-400 text-xs text-center">vs</span>
                        {mode === 'teamSwap' ? (
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
                                    {i > 0 && <span className="text-[10px] text-slate-400">&</span>}
                                    <span className="text-xs font-medium text-slate-200">{name(id)}</span>
                                  </span>
                                ))}
                              </button>
                            )
                          })()
                        ) : (
                          <div className="flex items-center gap-1 min-w-0">
                            {([0, 1] as const).map((i) => {
                              const id = g.teamB[i]
                              const n = name(id)
                              const isSelected =
                                (swapSelected?.slot === s && swapSelected?.court === g.court && swapSelected?.playerId === id) ||
                                !!(pendingSwap && (
                                  (pendingSwap.t1.slot === s && pendingSwap.t1.court === g.court && pendingSwap.t1.playerId === id) ||
                                  (pendingSwap.t2.slot === s && pendingSwap.t2.court === g.court && pendingSwap.t2.playerId === id)
                                ))
                              const isDimmed = !!pendingSwap && !isSelected
                              return (
                                <span key={i} className={`flex items-center gap-1 ${isDimmed ? 'opacity-30' : ''}`}>
                                  {i > 0 && <span className="text-[10px] text-slate-400">&</span>}
                                  <PlayerChipRenderer
                                    playerName={n}
                                    team="B"
                                    position={i}
                                    mode={mode}
                                    done={done}
                                    pendingSwap={pendingSwap}
                                    isSelected={isSelected}
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
                                    backToBackRuns={backToBackRuns.get(id)}
                                  />
                                </span>
                              )
                            })}
                          </div>
                        )}
                      </div>
                      {/* Score toggle / saved score */}
                      {mode === 'idle' && (savedScore && !isOpen ? (
                        <button
                          onClick={() => { if (!locked) { setExpandedScore(key); setScoreError(null); setDraftScores((d) => ({ ...d, [key]: { a: String(savedScore.a), b: String(savedScore.b) } })) } }}
                          className={`text-[11px] font-bold shrink-0 whitespace-nowrap ${locked ? 'text-slate-400 cursor-default' : 'text-emerald-400 hover:text-emerald-300'}`}
                        >
                          {savedScore.a}–{savedScore.b}
                        </button>
                      ) : !locked ? (
                        <button
                          onClick={() => {
                            if (isOpen) { setExpandedScore(null); setScoreError(null) }
                            else { setExpandedScore(key); setScoreError(null); setDraftScores((d) => ({ ...d, [key]: draft })) }
                          }}
                          className="text-[10px] text-slate-400 hover:text-slate-400 shrink-0 whitespace-nowrap transition-colors"
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
                            <span className="text-[10px] text-slate-400 truncate max-w-20 text-center">{teamANames}</span>
                            <input
                              type="number"
                              min={0}
                              max={99}
                              value={draft.a}
                              onChange={(e) => setDraftScores((d) => ({ ...d, [key]: { ...(d[key] ?? draft), a: e.target.value } }))}
                              className="w-14 bg-slate-800 border border-indigo-700 rounded-lg px-2 py-1.5 text-white font-bold text-lg text-center focus:outline-none focus:border-indigo-500 focus-visible:ring-2 focus-visible:ring-indigo-500/50"
                              aria-label={`Score for ${teamANames}`}
                            />
                          </div>
                          <span className="text-slate-400 font-bold text-lg mt-4">–</span>
                          <div className="flex flex-col items-center gap-1">
                            <span className="text-[10px] text-slate-400 truncate max-w-20 text-center">{teamBNames}</span>
                            <input
                              type="number"
                              min={0}
                              max={99}
                              value={draft.b}
                              onChange={(e) => setDraftScores((d) => ({ ...d, [key]: { ...(d[key] ?? draft), b: e.target.value } }))}
                              className="w-14 bg-elevated border border-border rounded-lg px-2 py-1.5 text-slate-300 font-bold text-lg text-center focus:outline-none focus:border-indigo-500 focus-visible:ring-2 focus-visible:ring-indigo-500/50"
                              aria-label={`Score for ${teamBNames}`}
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
