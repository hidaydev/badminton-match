import { useState } from 'react'
import type { GeneratorResult } from '../generator'
import type { Player, GameScore, CourtTime } from '../store'
import { timeToMinutes, minutesToTime } from '../store'
import { computeStandings } from '../utils/standings'
import type { SwapTarget } from '../utils/swap'

function ordinal(n: number): string {
  const s = ['th', 'st', 'nd', 'rd']
  const v = n % 100
  return n + (s[(v - 20) % 10] ?? s[v] ?? s[0])
}

function StandingsTab({
  players,
  schedule,
  gameScores,
}: {
  players: Player[]
  schedule: import('../store').ScheduleSlot[]
  gameScores: Record<string, GameScore>
}) {
  const standings = computeStandings(players, schedule, gameScores)
  const hasScores = Object.keys(gameScores).length > 0

  if (!hasScores) {
    return (
      <div className="flex items-center justify-center min-h-[200px]">
        <p className="text-sm text-slate-500 text-center">Enter scores in the Schedule tab to see standings.</p>
      </div>
    )
  }

  return (
    <div className="flex flex-col gap-1.5">
      {/* Header */}
      <div className="flex items-center gap-2 pl-2 pr-2 mb-1">
        <span className="w-[32px] text-[10px] font-bold text-slate-600 text-center shrink-0">#</span>
        <span className="flex-1 text-[10px] font-bold text-slate-600">Name</span>
        <span className="w-[44px] text-[10px] font-bold text-slate-600 text-center shrink-0">W-L</span>
        <span className="w-[36px] text-[10px] font-bold text-slate-600 text-center shrink-0">Diff</span>
        <span className="w-[36px] text-[10px] font-bold text-slate-600 text-center shrink-0">Pts</span>
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
            <div className="w-[32px] flex justify-center shrink-0">
              {medal
                ? <span className="text-lg leading-none">{medal}</span>
                : <span className="text-[11px] font-semibold text-slate-500">{ordinal(rank)}</span>
              }
            </div>
            <span className={`flex-1 min-w-0 truncate ${isFirst ? 'text-sm font-bold text-emerald-300' : isPodium ? 'text-sm font-semibold text-emerald-100/80' : 'text-sm font-medium text-slate-400'}`}>
              {s.player.name}
            </span>
            <span className={`w-[44px] text-[11px] font-semibold text-center shrink-0 ${wlColor}`}>{s.wins}-{s.losses}</span>
            <span className={`w-[36px] text-[11px] font-semibold text-center shrink-0 ${diffColor}`}>{diffLabel}</span>
            <span className={`w-[36px] text-sm font-bold text-center shrink-0 ${isFirst ? 'text-emerald-300' : isPodium ? 'text-emerald-100/70' : 'text-slate-400'}`}>{s.pointsFor}</span>
          </div>
        )
      })}
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
    // Same game → error
    if (swapSelected.slot === target.slot && swapSelected.court === target.court) {
      setSwapError('Cannot swap players in the same game')
      setSwapSelected(null)
      return
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
    if (!played.has(key)) onTogglePlayedGame(key)
    return true
  }

  function handleScoreSave(key: string) {
    if (trySaveScore(key)) setExpandedScore(null)
  }

  return (
    <div className={standalone ? 'flex-1 overflow-auto flex flex-col bg-slate-950' : 'fixed inset-0 z-50 bg-slate-950 overflow-auto flex flex-col'}>
      {pendingSwap && (
        <div className="fixed inset-0 z-[70] flex items-center justify-center bg-slate-950/80 px-6">
          <div className="bg-slate-900 border border-slate-700 rounded-2xl p-5 w-full max-w-xs text-center flex flex-col gap-3">
            <p className="text-sm font-bold text-white">Confirm Swap</p>
            <p className="text-xs text-slate-400 leading-relaxed">
              <span className="text-indigo-200 font-semibold">{playerMap.get(pendingSwap.t1.playerId)?.name}</span>
              {' '}(Slot {pendingSwap.t1.slot + 1}, Court {courtLabel(pendingSwap.t1.court)})
              {' '}⇄{' '}
              <span className="text-indigo-200 font-semibold">{playerMap.get(pendingSwap.t2.playerId)?.name}</span>
              {' '}(Slot {pendingSwap.t2.slot + 1}, Court {courtLabel(pendingSwap.t2.court)})
            </p>
            <p className="text-[11px] text-red-400">⚠ This cannot be undone.</p>
            <div className="flex gap-2">
              <button
                onClick={() => setPendingSwap(null)}
                className="flex-1 text-xs font-semibold py-2 rounded-lg bg-slate-800 border border-slate-600 text-slate-300 hover:text-white transition-colors"
              >
                Cancel
              </button>
              <button
                onClick={() => {
                  onSwapPlayers!(pendingSwap.t1, pendingSwap.t2)
                  exitSwapMode()
                }}
                disabled={saving}
                className="flex-1 text-xs font-bold py-2 rounded-lg bg-indigo-600 hover:bg-indigo-500 text-white transition-colors disabled:opacity-50"
              >
                {saving ? 'Saving…' : 'Confirm Swap'}
              </button>
            </div>
          </div>
        </div>
      )}
      {/* Toolbar */}
      <div className="flex items-center justify-between px-5 py-3 border-b border-slate-800 shrink-0">
        <div className="flex items-center gap-3">
          <div className="flex gap-1">
            <button
              onClick={() => { setActiveTab('schedule'); exitSwapMode() }}
              className={`text-xs font-semibold px-3 py-1.5 rounded-lg transition-colors ${activeTab === 'schedule' ? 'bg-indigo-900/60 border border-indigo-700 text-indigo-300' : 'text-slate-500 hover:text-slate-300'}`}
            >
              Schedule
            </button>
            <button
              onClick={() => { setActiveTab('standings'); exitSwapMode() }}
              className={`text-xs font-semibold px-3 py-1.5 rounded-lg transition-colors ${activeTab === 'standings' ? 'bg-indigo-900/60 border border-indigo-700 text-indigo-300' : 'text-slate-500 hover:text-slate-300'}`}
            >
              Standings
            </button>
          </div>
          {playedCount > 0 && (
            <span className="text-xs text-slate-500">
              {playedCount}/{totalGames} played
            </span>
          )}
        </div>
        <div className="flex items-center gap-2">
          {onSwapPlayers && activeTab === 'schedule' && (
            swapMode ? (
              <button
                onClick={exitSwapMode}
                className="text-xs font-semibold px-3 py-1.5 rounded-lg bg-slate-800 border border-slate-600 text-slate-300 hover:text-white transition-colors"
              >
                ✕ Cancel
              </button>
            ) : (
              <button
                onClick={() => setSwapMode(true)}
                className="text-xs font-semibold px-3 py-1.5 rounded-lg bg-indigo-900/20 border border-indigo-800/50 text-indigo-400 hover:text-indigo-300 transition-colors"
              >
                ⇄ Swap
              </button>
            )
          )}
          {onClose && (
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
        <div className="px-5 py-3 border-b border-slate-800 shrink-0">
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
      )}

      {/* Content */}
      <div className="flex-1 overflow-auto px-4 py-4 max-w-xl mx-auto w-full">
        {swapMode && (
          <div className="mb-3 rounded-lg bg-indigo-950/50 border border-indigo-800/40 px-3 py-2 flex flex-col gap-1">
            <span className="text-xs text-indigo-300 font-medium">
              {swapSelected
                ? '1 of 2 selected — tap a player from a different game'
                : 'Select two players from different games to swap'}
            </span>
            {swapError && (
              <span className="text-[11px] text-red-400">{swapError}</span>
            )}
          </div>
        )}
        {activeTab === 'standings' ? (
          <StandingsTab
            players={[...playerMap.values()]}
            schedule={result.schedule}
            gameScores={gameScores}
          />
        ) : (
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

                    return (
                      <div key={g.court} className="flex flex-col gap-1">
                        {/* Game row header */}
                        <div
                          className={`flex items-center gap-2 select-none rounded-lg px-1 py-0.5 -mx-1 transition-colors ${done ? 'opacity-40' : 'hover:bg-slate-800/40'}`}
                        >
                          {/* Played checkbox */}
                          <div
                            className={`w-4 h-4 shrink-0 rounded border flex items-center justify-center transition-colors ${saving ? 'cursor-not-allowed opacity-50' : 'cursor-pointer'} ${done ? 'bg-emerald-600 border-emerald-500' : 'border-slate-600 bg-slate-800'}`}
                            onClick={() => { if (!saving) onTogglePlayedGame(key) }}
                          >
                            {done && <span className="text-white text-[10px] font-bold leading-none">✓</span>}
                          </div>
                          {/* Teams */}
                          <div className="grid items-center gap-2 flex-1 min-w-0" style={{ gridTemplateColumns: 'auto 1fr auto 1fr' }}>
                            <span className="text-[10px] font-semibold text-slate-600 whitespace-nowrap">
                              {courtLabel(g.court)}
                            </span>
                            <div className="flex items-center gap-1 min-w-0">
                              {([0, 1] as const).map((i) => {
                                const id = g.teamA[i]
                                const n = name(id, s)
                                const target: SwapTarget = { slot: s, court: g.court, playerId: id, team: 'A', index: i }
                                const isSelected = swapSelected?.slot === s && swapSelected?.court === g.court && swapSelected?.playerId === id
                                return (
                                  <span key={i} className="flex items-center gap-1">
                                    {i > 0 && <span className="text-[10px] text-slate-600">&amp;</span>}
                                    {swapMode && !done ? (
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
                                    ) : (
                                      <span className={`text-xs font-medium ${done ? 'text-slate-400 line-through' : 'text-white'}`}>{n}</span>
                                    )}
                                  </span>
                                )
                              })}
                            </div>
                            <span className="text-slate-600 text-xs text-center">vs</span>
                            <div className="flex items-center gap-1 min-w-0">
                              {([0, 1] as const).map((i) => {
                                const id = g.teamB[i]
                                const n = name(id, s)
                                const target: SwapTarget = { slot: s, court: g.court, playerId: id, team: 'B', index: i }
                                const isSelected = swapSelected?.slot === s && swapSelected?.court === g.court && swapSelected?.playerId === id
                                return (
                                  <span key={i} className="flex items-center gap-1">
                                    {i > 0 && <span className="text-[10px] text-slate-600">&amp;</span>}
                                    {swapMode && !done ? (
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
                                    ) : (
                                      <span className={`text-xs font-medium ${done ? 'text-slate-400 line-through' : 'text-white'}`}>{n}</span>
                                    )}
                                  </span>
                                )
                              })}
                            </div>
                          </div>
                          {/* Score toggle / saved score */}
                          {savedScore && !isOpen ? (
                            <button
                              onClick={() => { setExpandedScore(key); setScoreError(null); setDraftScores((d) => ({ ...d, [key]: { a: String(savedScore.a), b: String(savedScore.b) } })) }}
                              className="text-[11px] font-bold text-emerald-400 shrink-0 whitespace-nowrap hover:text-emerald-300"
                            >
                              {savedScore.a}–{savedScore.b}
                            </button>
                          ) : (
                            <button
                              onClick={() => {
                                if (isOpen) { setExpandedScore(null); setScoreError(null) }
                                else { setExpandedScore(key); setScoreError(null); setDraftScores((d) => ({ ...d, [key]: draft })) }
                              }}
                              className="text-[10px] text-slate-600 hover:text-slate-400 shrink-0 whitespace-nowrap transition-colors"
                            >
                              {isOpen ? '▲ score' : '+ score'}
                            </button>
                          )}
                        </div>

                        {/* Expandable score panel */}
                        {isOpen && (
                          <div className="ml-6 bg-slate-900 border border-indigo-800/60 rounded-lg px-3 py-2.5 flex flex-col gap-2">
                            <div className="flex items-center justify-center gap-3">
                              <div className="flex flex-col items-center gap-1">
                                <span className="text-[10px] text-slate-500 truncate max-w-[80px] text-center">{teamANames}</span>
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
                                <span className="text-[10px] text-slate-500 truncate max-w-[80px] text-center">{teamBNames}</span>
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
                                className="px-6 py-1 rounded-lg bg-emerald-700 hover:bg-emerald-600 text-white text-xs font-bold transition-colors disabled:opacity-50 disabled:cursor-not-allowed"
                              >
                                {saving ? 'Saving…' : '✓ Save'}
                              </button>
                            </div>
                          </div>
                        )}
                      </div>
                    )
                  })}
                </div>
              </div>
            )
          })}
        </div>
        )}
      </div>
    </div>
  )
}
