import { useState } from 'react'
import { useStore, type Player, timeToMinutes } from '../store'
import { generate, type GeneratorResult } from '../generator'
import { useSharedView } from '../App'
import { buildShareUrl, type SharedSnapshot } from '../utils/shareUrl'

function SummaryModal({
  result,
  playerMap,
  slotsPerCourt,
  courtNames,
  onClose,
}: {
  result: GeneratorResult
  playerMap: Map<string, Player>
  slotsPerCourt: number[]
  courtNames: string[]
  onClose: () => void
}) {
  const courts = slotsPerCourt.length
  const maxSlots = Math.max(...slotsPerCourt)
  const playedArr = useStore((s) => s.playedGames)
  const togglePlayedGame = useStore((s) => s.togglePlayedGame)
  const played = new Set(playedArr)

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

  return (
    <div className="fixed inset-0 z-50 bg-slate-950 overflow-auto flex flex-col">
      {/* Toolbar */}
      <div className="flex items-center justify-between px-5 py-3 border-b border-slate-800 shrink-0">
        <div className="flex items-center gap-3">
          <span className="text-sm font-semibold text-white">Schedule</span>
          {playedCount > 0 && (
            <span className="text-xs text-slate-500">
              {playedCount}/{totalGames} played
            </span>
          )}
        </div>
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
                  {games.map((g) => {
                    const key = `${s}-${g.court}`
                    const done = played.has(key)
                    return (
                      <div
                        key={g.court}
                        className={`flex items-center gap-2 cursor-pointer select-none rounded-lg px-1 py-0.5 -mx-1 transition-colors ${done ? 'opacity-40' : 'hover:bg-slate-800/40'}`}
                        onClick={() => togglePlayedGame(key)}
                      >
                        <div className={`w-4 h-4 shrink-0 rounded border flex items-center justify-center transition-colors ${done ? 'bg-emerald-600 border-emerald-500' : 'border-slate-600 bg-slate-800'}`}>
                          {done && <span className="text-white text-[10px] font-bold leading-none">✓</span>}
                        </div>
                        <div className="grid items-center gap-2 flex-1 min-w-0" style={{ gridTemplateColumns: 'auto 1fr auto 1fr' }}>
                          <span className="text-[10px] font-semibold text-slate-600 whitespace-nowrap">
                            {courtLabel(g.court)}
                          </span>
                          <span className={`text-sm font-medium ${done ? 'text-slate-500 line-through' : 'text-white'}`}>
                            {name(g.teamA[0], s)} &amp; {name(g.teamA[1], s)}
                          </span>
                          <span className="text-slate-600 text-xs text-center">vs</span>
                          <span className={`text-sm font-medium ${done ? 'text-slate-500 line-through' : 'text-white'}`}>
                            {name(g.teamB[0], s)} &amp; {name(g.teamB[1], s)}
                          </span>
                        </div>
                      </div>
                    )
                  })}
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

function PlayerChip({ player, backToBack }: { player: Player; backToBack?: boolean }) {
  return (
    <span className="inline-flex items-center gap-1 bg-slate-700 rounded-lg px-2 py-1 text-xs text-white min-w-0 overflow-hidden">
      <span className="overflow-hidden">{player.name}</span>
      {backToBack && <span className="text-[10px] font-bold text-amber-400 shrink-0">*</span>}
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
  backToBackIds,
  courtName,
}: {
  court: number
  teamA: [string, string]
  teamB: [string, string]
  playerMap: Map<string, Player>
  backToBackIds?: Set<string>
  courtName?: string
}) {
  const getPlayer = (id: string) => playerMap.get(id)
  const tiersA = teamA.map((id) => playerMap.get(id)?.tier ?? 2)
  const tiersB = teamB.map((id) => playerMap.get(id)?.tier ?? 2)

  return (
    <div className="bg-slate-800 border border-slate-700 rounded-xl px-3 py-2 flex flex-col gap-1.5">
      <div className="flex items-center justify-between">
        <span className="text-[10px] text-slate-500 font-medium">{courtName || `Court ${court + 1}`}</span>
        <TierBalance tiersA={tiersA} tiersB={tiersB} />
      </div>
      <div className="flex items-center gap-2">
        <div className="flex gap-1 flex-1 min-w-0 overflow-hidden">
          {teamA.map((id) => {
            const p = getPlayer(id)
            return p ? <PlayerChip key={id} player={p} backToBack={backToBackIds?.has(id)} /> : null
          })}
        </div>
        <span className="text-slate-500 text-xs font-bold shrink-0">vs</span>
        <div className="flex gap-1 flex-1 min-w-0 overflow-hidden">
          {teamB.map((id) => {
            const p = getPlayer(id)
            return p ? <PlayerChip key={id} player={p} backToBack={backToBackIds?.has(id)} /> : null
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
  courtNames,
}: {
  result: GeneratorResult
  playerMap: Map<string, Player>
  slotsPerCourt: number[]
  courtNames: string[]
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

  // Players per slot (for back-to-back detection)
  const slotPlayerSet = new Map<number, Set<string>>()
  for (const [t, games] of bySlot) {
    const set = new Set<string>()
    for (const g of games) {
      g.teamA.forEach((id) => set.add(id))
      g.teamB.forEach((id) => set.add(id))
    }
    slotPlayerSet.set(t, set)
  }
  const backToBackAt = (t: number): Set<string> => {
    const cur = slotPlayerSet.get(t)
    if (!cur) return new Set()
    const out = new Set<string>()
    const prev = slotPlayerSet.get(t - 1)
    const next = slotPlayerSet.get(t + 1)
    for (const id of cur) {
      if (prev?.has(id) || next?.has(id)) out.add(id)
    }
    return out
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
                    backToBackIds={backToBackAt(t)}
                    courtName={courtNames[g.court]}
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

  // Fix-forced partner pairs
  const fixForcedPairs: Record<string, number> = {}
  // Fix-forced opponent pairs
  const fixForcedOpponents: Record<string, number> = {}
  for (const fm of fixMatches) {
    const [a1, a2, b1, b2] = fm.slots
    if (a1 && a2) { const k = [a1, a2].sort().join('|'); fixForcedPairs[k] = (fixForcedPairs[k] ?? 0) + 1 }
    if (b1 && b2) { const k = [b1, b2].sort().join('|'); fixForcedPairs[k] = (fixForcedPairs[k] ?? 0) + 1 }
    for (const a of [a1, a2].filter(Boolean)) {
      for (const b of [b1, b2].filter(Boolean)) {
        const k = [a, b].sort().join('|')
        fixForcedOpponents[k] = (fixForcedOpponents[k] ?? 0) + 1
      }
    }
  }

  let repeatedPairs = 0
  let excludedPairs = 0
  const seenPairs = new Set<string>()
  for (const [a, partners] of Object.entries(result.partnerWith)) {
    for (const [b, count] of Object.entries(partners)) {
      const key = [a, b].sort().join('|')
      if (!seenPairs.has(key)) {
        seenPairs.add(key)
        const forced = fixForcedPairs[key] ?? 0
        const organic = count - forced
        if (forced > 0) excludedPairs++
        if (organic >= 2) repeatedPairs++
      }
    }
  }

  let repeatedOpponents = 0
  let excludedOpponents = 0
  const seenOpponents = new Set<string>()
  for (const [a, faced] of Object.entries(result.facedBy)) {
    for (const [b, count] of Object.entries(faced)) {
      const key = [a, b].sort().join('|')
      if (!seenOpponents.has(key)) {
        seenOpponents.add(key)
        const forced = fixForcedOpponents[key] ?? 0
        const organic = count - forced
        if (forced > 0) excludedOpponents++
        if (organic >= 2) repeatedOpponents++
      }
    }
  }

  return { playSpread: maxPlays - minPlays, minPlays, maxPlays, unevenGames, backToBackCount, repeatedPairs, excludedPairs, repeatedOpponents, excludedOpponents, totalGames: result.schedule.length }
}

function QualityBanner({ result, playerMap, fixMatches, onRetryUntilGood, retryInfo }: {
  result: GeneratorResult
  playerMap: Map<string, Player>
  fixMatches: import('../store').FixMatch[]
  onRetryUntilGood?: () => void
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

    q.repeatedPairs === 0
      ? { label: 'Partner variety', detail: 'all unique', level: 'ok' as Level, hint: q.excludedPairs > 0 ? `${q.excludedPairs} pair${q.excludedPairs > 1 ? 's' : ''} excluded (constrained)` : undefined }
      : { label: 'Partner variety', detail: `${q.repeatedPairs} pair${q.repeatedPairs > 1 ? 's' : ''} repeated`, level: (q.repeatedPairs >= 3 ? 'bad' : 'warn') as Level, hint: q.excludedPairs > 0 ? `${q.excludedPairs} pair${q.excludedPairs > 1 ? 's' : ''} excluded (constrained)` : undefined },

    q.repeatedOpponents === 0
      ? { label: 'Opponent variety', detail: 'all unique', level: 'ok' as Level, hint: q.excludedOpponents > 0 ? `${q.excludedOpponents} pair${q.excludedOpponents > 1 ? 's' : ''} excluded (constrained)` : undefined }
      : { label: 'Opponent variety', detail: `${q.repeatedOpponents} pair${q.repeatedOpponents > 1 ? 's' : ''} repeated`, level: (q.repeatedOpponents >= 3 ? 'bad' : 'warn') as Level, hint: q.excludedOpponents > 0 ? `${q.excludedOpponents} pair${q.excludedOpponents > 1 ? 's' : ''} excluded (constrained)` : undefined },
  ]

  const backToBackItem = { label: 'Back-to-back', detail: q.backToBackCount === 0 ? 'none' : `${q.backToBackCount} instance${q.backToBackCount > 1 ? 's' : ''}`, level: q.backToBackCount > 0 ? 'warn' as Level : 'ok' as Level }

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
        {(hasBad || hasWarn) && onRetryUntilGood && (
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
        <div className="col-span-2 flex items-center gap-1.5 min-w-0">
          <div className={`w-1.5 h-1.5 rounded-full shrink-0 ${dot[backToBackItem.level]}`} />
          <span className="text-[11px] text-slate-500 shrink-0">{backToBackItem.label}:</span>
          <span className={`text-[11px] font-medium ${text[backToBackItem.level]}`}>{backToBackItem.detail}</span>
        </div>
      </div>
    </div>
  )
}

export default function GeneratePage() {
  const { isSharedView, snapshot, exitSharedView } = useSharedView()

  const storePlayers = useStore((s) => s.players)
  const storeFixMatches = useStore((s) => s.fixMatches)
  const storeSession = useStore((s) => s.session)
  const storeSessionId = useStore((s) => s.sessionId)
  const storeResult = useStore((s) => s.lastResult)
  const setStoreResult = useStore((s) => s.setResult)

  const players = isSharedView ? (snapshot?.players ?? []) : storePlayers
  const fixMatches = isSharedView ? [] : storeFixMatches
  const session = isSharedView ? (snapshot?.session ?? storeSession) : storeSession
  const sessionId = isSharedView ? (snapshot?.sessionId ?? storeSessionId) : storeSessionId

  const showSummary = useStore((s) => s.summaryOpen)
  const setShowSummary = useStore((s) => s.setSummaryOpen)
  const [result, setResult] = useState<GeneratorResult | null>(
    isSharedView ? (snapshot?.lastResult ?? null) : storeResult
  )
  const [error, setError] = useState<string | null>(null)
  const [retryInfo, setRetryInfo] = useState<{ attempts: number; perfect: boolean } | null>(null)
  const [copied, setCopied] = useState(false)

  const playerMap = new Map(players.map((p) => [p.id, p]))

  async function handleShare() {
    if (!result) return
    const payload: SharedSnapshot = {
      sessionId,
      session,
      players,
      schedule: result.schedule,
      lastResult: result,
    }
    const url = buildShareUrl(payload)
    await navigator.clipboard.writeText(url)
    setCopied(true)
    setTimeout(() => setCopied(false), 2000)
  }

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
            <h2 className="text-xl sm:text-2xl font-bold text-white">Generate Schedule</h2>
            {result && !isSharedView && (
              <button
                onClick={handleShare}
                className={`flex items-center gap-1.5 px-2 py-1 rounded-lg text-xs font-medium transition-colors ${copied ? 'text-emerald-400 bg-emerald-900/30' : 'text-slate-400 hover:text-white hover:bg-slate-800'}`}
              >
                {copied ? (
                  <>
                    <svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.5" strokeLinecap="round" strokeLinejoin="round">
                      <polyline points="20 6 9 17 4 12"/>
                    </svg>
                    Copied!
                  </>
                ) : (
                  <>
                    <svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
                      <circle cx="18" cy="5" r="3"/><circle cx="6" cy="12" r="3"/><circle cx="18" cy="19" r="3"/>
                      <line x1="8.59" y1="13.51" x2="15.42" y2="17.49"/><line x1="15.41" y1="6.51" x2="8.59" y2="10.49"/>
                    </svg>
                    Share
                  </>
                )}
              </button>
            )}
          </div>
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
            {!isSharedView && (
              <>
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
              </>
            )}
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
          <QualityBanner result={result} playerMap={playerMap} fixMatches={fixMatches} onRetryUntilGood={isSharedView ? undefined : handleRetryUntilGood} retryInfo={retryInfo} />
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
          courtNames={session.courtNames ?? []}
        />
      )}

      {showSummary && result && (
        <SummaryModal
          result={result}
          playerMap={playerMap}
          slotsPerCourt={session.slotsPerCourt}
          courtNames={session.courtNames ?? []}
          onClose={() => setShowSummary(false)}
        />
      )}
    </div>
  )
}
