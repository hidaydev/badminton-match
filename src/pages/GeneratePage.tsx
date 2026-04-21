import { useState } from 'react'
import { useStore, type Player, timeToMinutes } from '../store'
import { generate, type GeneratorResult } from '../generator'

function SummaryModal({
  result,
  playerMap,
  slotsPerCourt,
  onClose,
}: {
  result: GeneratorResult
  playerMap: Map<string, Player>
  slotsPerCourt: number[]
  onClose: () => void
}) {
  const courts = slotsPerCourt.length
  const maxSlots = Math.max(...slotsPerCourt)

  const bySlot = new Map<number, (typeof result.schedule)>()
  for (const game of result.schedule) {
    const list = bySlot.get(game.slot) ?? []
    list.push(game)
    bySlot.set(game.slot, list)
  }

  const name = (id: string) => playerMap.get(id)?.name ?? id
  const courtLabel = (i: number) =>
    courts <= 26 ? String.fromCharCode(65 + i) : String(i + 1)

  return (
    <div className="fixed inset-0 z-50 bg-slate-950 overflow-auto flex flex-col">
      {/* Toolbar */}
      <div className="flex items-center justify-between px-5 py-3 border-b border-slate-800 shrink-0">
        <span className="text-sm font-semibold text-white">Schedule</span>
        <button
          onClick={onClose}
          className="text-slate-400 hover:text-white px-3 py-1.5 rounded-lg hover:bg-slate-800 transition-colors text-sm"
        >
          Close
        </button>
      </div>

      {/* Content */}
      <div className="flex-1 overflow-auto px-4 py-4 max-w-xl mx-auto w-full">
        <div className="flex flex-col divide-y divide-slate-800">
          {Array.from({ length: maxSlots }, (_, s) => {
            const games = (bySlot.get(s) ?? []).sort((a, b) => a.court - b.court)
            return (
              <div key={s} className="flex items-start gap-4 py-4">
                <span className="text-xs font-bold text-slate-600 w-10 shrink-0 pt-0.5">
                  #{s + 1}
                </span>
                <div className="flex flex-col gap-2.5 flex-1">
                  {games.map((g) => (
                    <div key={g.court} className="grid items-center gap-2" style={{ gridTemplateColumns: '1rem 1fr auto 1fr' }}>
                      <span className="text-[10px] font-semibold text-slate-600">
                        {courtLabel(g.court)}
                      </span>
                      <span className="text-sm font-medium text-white">
                        {name(g.teamA[0])} &amp; {name(g.teamA[1])}
                      </span>
                      <span className="text-slate-600 text-xs text-center">vs</span>
                      <span className="text-sm font-medium text-white">
                        {name(g.teamB[0])} &amp; {name(g.teamB[1])}
                      </span>
                    </div>
                  ))}
                </div>
              </div>
            )
          })}
        </div>
      </div>
    </div>
  )
}

const TIER_LABEL: Record<number, string> = { 1: 'A', 2: 'B', 3: 'C', 4: 'D' }
const TIER_COLOR: Record<number, string> = { 1: 'text-red-400', 2: 'text-orange-400', 3: 'text-yellow-400', 4: 'text-green-400' }

function PlayerChip({ player }: { player: Player }) {
  return (
    <span className="inline-flex items-center gap-1 bg-slate-700 rounded-lg px-2 py-1 text-xs text-white min-w-0 overflow-hidden">
      <span className="overflow-hidden">{player.name}</span>
      <span className={`hidden sm:inline text-[10px] font-bold shrink-0 ${player.gender === 'M' ? 'text-blue-400' : 'text-pink-400'}`}>
        {player.gender}
      </span>
      <span className={`hidden sm:inline text-[10px] font-bold shrink-0 ${TIER_COLOR[player.tier]}`}>{TIER_LABEL[player.tier]}</span>
    </span>
  )
}

function TierBalance({ tiersA, tiersB }: { tiersA: number[]; tiersB: number[] }) {
  const sumA = tiersA.reduce((a, b) => a + b, 0)
  const sumB = tiersB.reduce((a, b) => a + b, 0)
  const diff = Math.abs(sumA - sumB)
  const badge = diff === 0 ? 'balanced' : `±${diff}`
  const color = diff === 0
    ? 'text-emerald-400 bg-emerald-900/30 border-emerald-800'
    : diff === 1
    ? 'text-amber-400 bg-amber-900/30 border-amber-800'
    : 'text-red-400 bg-red-900/30 border-red-800'
  const TierLetters = ({ tiers }: { tiers: number[] }) => (
    <span>{tiers.map((t, i) => <span key={i} className={`text-[10px] font-bold ${TIER_COLOR[t] ?? 'text-slate-400'}`}>{TIER_LABEL[t] ?? t}</span>)}</span>
  )
  return (
    <div className="flex items-center gap-1.5">
      <span className="text-[10px] text-slate-600"><TierLetters tiers={tiersA} /> vs <TierLetters tiers={tiersB} /></span>
      <span className={`text-[10px] px-1.5 py-0.5 rounded border font-medium ${color}`}>{badge}</span>
    </div>
  )
}

function GameCard({
  court,
  teamA,
  teamB,
  playerMap,
}: {
  court: number
  teamA: [string, string]
  teamB: [string, string]
  playerMap: Map<string, Player>
}) {
  const getPlayer = (id: string) => playerMap.get(id)
  const tiersA = teamA.map((id) => playerMap.get(id)?.tier ?? 2)
  const tiersB = teamB.map((id) => playerMap.get(id)?.tier ?? 2)

  return (
    <div className="bg-slate-800 border border-slate-700 rounded-xl px-3 py-2 flex flex-col gap-1.5">
      <div className="flex items-center justify-between">
        <span className="text-[10px] text-slate-500 font-medium">Court {court + 1}</span>
        <TierBalance tiersA={tiersA} tiersB={tiersB} />
      </div>
      <div className="flex items-center gap-2">
        <div className="flex gap-1 flex-1 min-w-0 overflow-hidden">
          {teamA.map((id) => {
            const p = getPlayer(id)
            return p ? <PlayerChip key={id} player={p} /> : null
          })}
        </div>
        <span className="text-slate-500 text-xs font-bold shrink-0">vs</span>
        <div className="flex gap-1 flex-1 min-w-0 overflow-hidden">
          {teamB.map((id) => {
            const p = getPlayer(id)
            return p ? <PlayerChip key={id} player={p} /> : null
          })}
        </div>
      </div>
    </div>
  )
}

function ScheduleView({
  result,
  playerMap,
  slotsPerCourt,
}: {
  result: GeneratorResult
  playerMap: Map<string, Player>
  slotsPerCourt: number[]
}) {
  const maxSlots = Math.max(...slotsPerCourt)
  const players = [...playerMap.values()]

  // Group games by time slot
  const bySlot = new Map<number, typeof result.schedule>()
  for (const game of result.schedule) {
    const list = bySlot.get(game.slot) ?? []
    list.push(game)
    bySlot.set(game.slot, list)
  }

  // Who sits out each slot
  const sittingOut = (t: number) => {
    const playing = new Set<string>()
    for (const g of bySlot.get(t) ?? []) {
      g.teamA.forEach((id) => playing.add(id))
      g.teamB.forEach((id) => playing.add(id))
    }
    return players.filter((p) => !playing.has(p.id))
  }

  const idealPlays = (result.schedule.length * 4) / players.length

  return (
    <div className="flex flex-col gap-8">
      {/* Schedule by time slot */}
      <div className="flex flex-col gap-4">
        {Array.from({ length: maxSlots }, (_, t) => {
          const games = bySlot.get(t) ?? []
          const out = sittingOut(t)
          return (
            <div key={t} className="flex flex-col gap-2">
              <div className="flex items-center gap-3">
                <span className="text-xs font-semibold text-slate-400 w-12 shrink-0">Slot {t + 1}</span>
                <div className="flex-1 h-px bg-slate-800" />
              </div>
              <div className="flex flex-col gap-2 pl-2">
                {games.map((g) => (
                  <GameCard
                    key={`${g.court}-${g.slot}`}
                    court={g.court}
                    teamA={g.teamA}
                    teamB={g.teamB}
                    playerMap={playerMap}
                  />
                ))}
                {out.length > 0 && (
                  <div className="flex items-center gap-2 flex-wrap mt-1">
                    <span className="text-[10px] text-slate-600">sits out:</span>
                    {out.map((p) => (
                      <span key={p.id} className="text-[10px] text-slate-500 bg-slate-800/50 px-1.5 py-0.5 rounded">
                        {p.name}
                      </span>
                    ))}
                  </div>
                )}
              </div>
            </div>
          )
        })}
      </div>

      {/* Player stats */}
      <div className="bg-slate-900 border border-slate-800 rounded-2xl p-3 flex flex-col gap-2">
        <div className="flex items-center justify-between">
          <span className="text-sm font-semibold text-white">Player Stats</span>
          <span className="text-xs text-slate-500">target ~{idealPlays.toFixed(1)} plays</span>
        </div>
        <div className="grid grid-cols-1 gap-y-2">
          {players
            .sort((a, b) => (result.playCount[b.id] ?? 0) - (result.playCount[a.id] ?? 0))
            .map((p) => {
              const plays = result.playCount[p.id] ?? 0
              const sits = result.sitCount[p.id] ?? 0
              const partners = Object.keys(result.partnerWith[p.id] ?? {}).length
              const opponents = Object.keys(result.facedBy[p.id] ?? {}).length
              const over = plays > Math.ceil(idealPlays)
              const under = plays < Math.floor(idealPlays)
              return (
                <div key={p.id} className="flex items-center gap-2">
                  <span className="text-xs text-slate-300 w-20 truncate">{p.name}</span>
                  <span className={`text-xs font-bold w-8 ${over ? 'text-amber-400' : under ? 'text-sky-400' : 'text-emerald-400'}`}>
                    {plays}×
                  </span>
                  <span className="text-[10px] text-slate-600">
                    {sits} sit · {partners} P · {opponents} O
                  </span>
                </div>
              )
            })}
        </div>
        <p className="text-[10px] text-slate-600">P = unique partners · O = unique opponents faced</p>
      </div>
    </div>
  )
}

// ── Quality analysis ──────────────────────────────────────────────────────────

function computeQuality(result: GeneratorResult, playerMap: Map<string, Player>, fixMatches: import('../store').FixMatch[]) {
  const players = [...playerMap.values()]
  if (players.length === 0 || result.schedule.length === 0) return null

  const plays = players.map((p) => result.playCount[p.id] ?? 0)
  const minPlays = Math.min(...plays)
  const maxPlays = Math.max(...plays)

  let unevenGames = 0
  for (const g of result.schedule) {
    const tierA = (playerMap.get(g.teamA[0])?.tier ?? 2) + (playerMap.get(g.teamA[1])?.tier ?? 2)
    const tierB = (playerMap.get(g.teamB[0])?.tier ?? 2) + (playerMap.get(g.teamB[1])?.tier ?? 2)
    if (Math.abs(tierA - tierB) >= 2) unevenGames++
  }

  const slotPlayers = new Map<number, Set<string>>()
  for (const g of result.schedule) {
    const set = slotPlayers.get(g.slot) ?? new Set<string>()
    g.teamA.forEach((id) => set.add(id))
    g.teamB.forEach((id) => set.add(id))
    slotPlayers.set(g.slot, set)
  }
  const slots = [...slotPlayers.keys()].sort((a, b) => a - b)
  let backToBackCount = 0
  for (let i = 0; i < slots.length - 1; i++) {
    if (slots[i + 1] !== slots[i] + 1) continue
    const cur = slotPlayers.get(slots[i])!
    const nxt = slotPlayers.get(slots[i + 1])!
    for (const id of cur) if (nxt.has(id)) backToBackCount++
  }

  // Count how many times each pair is forced by fix matches
  const fixForcedPairs: Record<string, number> = {}
  for (const fm of fixMatches) {
    const [a1, a2, b1, b2] = fm.slots
    if (a1 && a2) { const k = [a1, a2].sort().join('|'); fixForcedPairs[k] = (fixForcedPairs[k] ?? 0) + 1 }
    if (b1 && b2) { const k = [b1, b2].sort().join('|'); fixForcedPairs[k] = (fixForcedPairs[k] ?? 0) + 1 }
  }

  let repeatedPairs = 0
  let excludedPairs = 0
  const seen = new Set<string>()
  for (const [a, partners] of Object.entries(result.partnerWith)) {
    for (const [b, count] of Object.entries(partners)) {
      const key = [a, b].sort().join('|')
      if (!seen.has(key)) {
        seen.add(key)
        const forced = fixForcedPairs[key] ?? 0
        const organic = count - forced
        if (forced > 0) excludedPairs++
        if (organic >= 2) repeatedPairs++
      }
    }
  }

  return { playSpread: maxPlays - minPlays, minPlays, maxPlays, unevenGames, backToBackCount, repeatedPairs, excludedPairs, totalGames: result.schedule.length }
}

function QualityBanner({ result, playerMap, fixMatches, onRetryUntilGood, retryInfo }: {
  result: GeneratorResult
  playerMap: Map<string, Player>
  fixMatches: import('../store').FixMatch[]
  onRetryUntilGood: () => void
  retryInfo: { attempts: number; perfect: boolean } | null
}) {
  const q = computeQuality(result, playerMap, fixMatches)
  if (!q) return null

  type Level = 'ok' | 'warn' | 'bad'
  const items: { label: string; detail: string; level: Level; hint?: string; infoOnly?: boolean }[] = [
    q.playSpread === 0
      ? { label: 'Play count', detail: 'perfectly balanced', level: 'ok' }
      : q.playSpread === 1
      ? { label: 'Play count', detail: `±1 (${q.minPlays}–${q.maxPlays}×)`, level: 'ok' }
      : { label: 'Play count', detail: `spread ${q.playSpread} (${q.minPlays}–${q.maxPlays}×)`, level: q.playSpread >= 3 ? 'bad' : 'warn' },

    q.unevenGames === 0
      ? { label: 'Match balance', detail: 'all fair', level: 'ok' }
      : { label: 'Match balance', detail: `${q.unevenGames} uneven game${q.unevenGames > 1 ? 's' : ''}`, level: q.unevenGames / q.totalGames > 0.3 ? 'bad' : 'warn' },

    { label: 'Back-to-back', detail: q.backToBackCount === 0 ? 'none' : `${q.backToBackCount} instance${q.backToBackCount > 1 ? 's' : ''}`, level: q.backToBackCount > 0 ? 'warn' as Level : 'ok' as Level, infoOnly: true },

    q.repeatedPairs === 0
      ? { label: 'Partner variety', detail: 'all unique', level: 'ok' as Level, hint: q.excludedPairs > 0 ? `${q.excludedPairs} pair${q.excludedPairs > 1 ? 's' : ''} excluded (constrained)` : undefined }
      : { label: 'Partner variety', detail: `${q.repeatedPairs} pair${q.repeatedPairs > 1 ? 's' : ''} repeated`, level: (q.repeatedPairs >= 3 ? 'bad' : 'warn') as Level, hint: q.excludedPairs > 0 ? `${q.excludedPairs} pair${q.excludedPairs > 1 ? 's' : ''} excluded (constrained)` : undefined },
  ]

  const hasBad = items.some((i) => i.level === 'bad' && !i.infoOnly)
  const hasWarn = items.some((i) => i.level === 'warn' && !i.infoOnly)
  const dot: Record<Level, string> = { ok: 'bg-emerald-400', warn: 'bg-amber-400', bad: 'bg-red-400' }
  const text: Record<Level, string> = { ok: 'text-emerald-400', warn: 'text-amber-400', bad: 'text-red-400' }

  return (
    <div className={`rounded-2xl border p-3 flex flex-col gap-2.5 ${
      hasBad ? 'bg-red-900/20 border-red-800' : hasWarn ? 'bg-amber-900/20 border-amber-800' : 'bg-emerald-900/20 border-emerald-800'
    }`}>
      <div className="flex items-center justify-between">
        <div className="flex items-center gap-2">
          <span className={`text-sm font-semibold ${hasBad ? 'text-red-400' : hasWarn ? 'text-amber-400' : 'text-emerald-400'}`}>
            {hasBad ? '⚠ Consider regenerating' : hasWarn ? '~ Could be better' : '✓ Good schedule'}
          </span>
          {retryInfo && (
            <span className="text-[11px] text-slate-500">
              {retryInfo.perfect ? `· found in ${retryInfo.attempts} attempt${retryInfo.attempts > 1 ? 's' : ''}` : `· best of ${retryInfo.attempts} attempts`}
            </span>
          )}
        </div>
        {(hasBad || hasWarn) && (
          <button
            onClick={onRetryUntilGood}
            className="text-xs px-2.5 py-1 rounded-lg bg-emerald-900/40 hover:bg-emerald-900/60 border border-emerald-800 text-emerald-400 hover:text-emerald-200 transition-colors"
          >
            ↺ Retry until good
          </button>
        )}
      </div>
      <div className="grid grid-cols-2 gap-x-3 gap-y-1.5">
        {items.map((item) => (
          <div key={item.label} className="flex items-center gap-1.5 min-w-0">
            <div className={`w-1.5 h-1.5 rounded-full shrink-0 ${dot[item.level]}`} />
            <span className="text-[11px] text-slate-500 shrink-0">{item.label}:</span>
            <span className={`text-[11px] font-medium truncate ${text[item.level]}`}>{item.detail}</span>
            {item.hint && (
              <span title={item.hint} className="text-[10px] text-slate-600 hover:text-slate-400 cursor-help shrink-0">ⓘ</span>
            )}
          </div>
        ))}
      </div>
    </div>
  )
}

export default function GeneratePage() {
  const players = useStore((s) => s.players)
  const fixMatches = useStore((s) => s.fixMatches)
  const session = useStore((s) => s.session)
  const storeResult = useStore((s) => s.lastResult)
  const setStoreResult = useStore((s) => s.setResult)

  const [result, setResult] = useState<GeneratorResult | null>(storeResult)
  const [error, setError] = useState<string | null>(null)
  const [showSummary, setShowSummary] = useState(false)
  const [retryInfo, setRetryInfo] = useState<{ attempts: number; perfect: boolean } | null>(null)

  const playerMap = new Map(players.map((p) => [p.id, p]))

  function buildOffsets() {
    return session.courtTimes.map((ct) =>
      Math.floor((timeToMinutes(ct.start) - timeToMinutes(session.sessionStart)) / session.slotMinutes)
    )
  }

  function validatePlayers() {
    if (players.length < 4) return 'Need at least 4 players.'
    if (players.length < session.slotsPerCourt.length * 4)
      return `Need at least ${session.slotsPerCourt.length * 4} players for ${session.slotsPerCourt.length} courts.`
    return null
  }

  function qualityScore(r: GeneratorResult) {
    const q = computeQuality(r, playerMap, fixMatches)
    if (!q) return Infinity
    return q.playSpread * 10 + q.unevenGames * 2 + q.repeatedPairs * 3
  }

  function isGood(r: GeneratorResult) {
    const q = computeQuality(r, playerMap, fixMatches)
    if (!q) return false
    return q.playSpread <= 1 && q.unevenGames === 0 && q.repeatedPairs === 0
  }

  function handleGenerate() {
    setError(null)
    setRetryInfo(null)
    const err = validatePlayers()
    if (err) { setError(err); return }
    try {
      const r = generate(players, session.slotsPerCourt, fixMatches, buildOffsets())
      setResult(r)
      setStoreResult(r)
    } catch (e) {
      setError(String(e))
    }
  }

  function handleRetryUntilGood() {
    setError(null)
    const err = validatePlayers()
    if (err) { setError(err); return }
    try {
      const offsets = buildOffsets()
      let best = generate(players, session.slotsPerCourt, fixMatches, offsets)
      let attempts = 1
      const MAX = 30
      while (attempts < MAX && !isGood(best)) {
        const candidate = generate(players, session.slotsPerCourt, fixMatches, offsets)
        if (qualityScore(candidate) < qualityScore(best)) best = candidate
        attempts++
        if (isGood(best)) break
      }
      setResult(best)
      setStoreResult(best)
      setRetryInfo({ attempts, perfect: isGood(best) })
    } catch (e) {
      setError(String(e))
    }
  }

  return (
    <div className="flex flex-col gap-6">
      <div className="flex flex-wrap items-start justify-between gap-2">
        <div>
          <h2 className="text-xl sm:text-2xl font-bold text-white mb-0.5">Generate Schedule</h2>
          <p className="text-slate-400 text-xs sm:text-sm">
            {players.length} players · {session.totalGames} games · {session.courts} court{session.courts > 1 ? 's' : ''}
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
            <button
              onClick={handleGenerate}
              className="text-xs text-slate-400 hover:text-slate-200 px-2.5 py-1.5 rounded-lg bg-slate-800 hover:bg-slate-700 transition-colors whitespace-nowrap"
            >
              Regenerate
            </button>
            <button
              onClick={handleRetryUntilGood}
              className="text-xs text-emerald-400 hover:text-emerald-200 px-2.5 py-1.5 rounded-lg bg-emerald-900/30 hover:bg-emerald-900/50 border border-emerald-800 transition-colors whitespace-nowrap"
            >
              ↺ Until good
            </button>
          </div>
        )}
      </div>

      {error && (
        <div className="p-3 bg-red-900/30 border border-red-700 rounded-xl text-red-400 text-sm">
          {error}
        </div>
      )}

      {result && result.unplacedFixMatches.length > 0 && (
        <div className="p-3 bg-amber-900/30 border border-amber-700 rounded-xl text-amber-400 text-sm flex flex-col gap-1.5">
          <span className="font-medium">⚠ {result.unplacedFixMatches.length} fix match{result.unplacedFixMatches.length > 1 ? 'es' : ''} could not be placed:</span>
          {result.unplacedFixMatches.map((id) => {
            const fm = fixMatches.find((m) => m.id === id)
            if (!fm) return null
            const name = (pid: string) => playerMap.get(pid)?.name ?? '?'
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
          <QualityBanner result={result} playerMap={playerMap} fixMatches={fixMatches} onRetryUntilGood={handleRetryUntilGood} retryInfo={retryInfo} />
        </>
      )}

      {!result ? (
        <button
          onClick={handleGenerate}
          disabled={players.length < 4}
          className="w-full py-2.5 bg-indigo-600 hover:bg-indigo-500 disabled:opacity-40 disabled:cursor-not-allowed text-white font-bold text-base rounded-2xl transition-colors"
        >
          ▶ Generate Schedule
        </button>
      ) : (
        <ScheduleView
          result={result}
          playerMap={playerMap}
          slotsPerCourt={session.slotsPerCourt}
        />
      )}

      {showSummary && result && (
        <SummaryModal
          result={result}
          playerMap={playerMap}
          slotsPerCourt={session.slotsPerCourt}
          onClose={() => setShowSummary(false)}
        />
      )}
    </div>
  )
}
