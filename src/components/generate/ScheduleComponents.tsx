// src/components/generate/ScheduleComponents.tsx
// Extracted inline components from GeneratePage.

import type { Player, MatchConstraint, ScheduleSlot } from '../../types'
import type { GeneratorResult } from '../../generator'
import { TIER_LABELS, TIER_COLORS } from '../../config/tiers'
import { computePlayerStats } from '../../utils/playerStats'
import { computeQuality } from '../../utils/quality'

// ── Tier letters ─────────────────────────────────────────────────────────────

function renderTierLetters(tiers: number[]) {
  return tiers.map((tier, index) => (
    <span
      key={`${tier}-${index}`}
      className={`text-[10px] font-bold ${TIER_COLORS[tier] ?? 'text-slate-400'}`}
    >
      {TIER_LABELS[tier] ?? tier}
    </span>
  ))
}

// ── Player chip ──────────────────────────────────────────────────────────────

export function PlayerChip({ player, backToBack }: { player: Player; backToBack?: boolean }) {
  return (
    <span className="inline-flex items-center gap-1 bg-slate-700 rounded-lg px-2 py-1 text-xs text-white min-w-0 overflow-hidden">
      <span className="overflow-hidden">{player.name}</span>
      {backToBack && <span className="text-[10px] font-bold text-amber-400 shrink-0">*</span>}
      <span className={`hidden sm:inline text-[10px] font-bold shrink-0 ${player.gender === 'M' ? 'text-blue-400' : 'text-pink-400'}`}>
        {player.gender}
      </span>
      <span className={`hidden sm:inline text-[10px] font-bold shrink-0 ${TIER_COLORS[player.tier]}`}>{TIER_LABELS[player.tier]}</span>
    </span>
  )
}

// ── Tier balance badge ───────────────────────────────────────────────────────

export function TierBalance({ tiersA, tiersB }: { tiersA: number[]; tiersB: number[] }) {
  const sumA = tiersA.reduce((a, b) => a + b, 0)
  const sumB = tiersB.reduce((a, b) => a + b, 0)
  const diff = Math.abs(sumA - sumB)
  const badge = diff === 0 ? 'balanced' : `±${diff}`
  const color = diff === 0
    ? 'text-emerald-400 bg-emerald-900/30 border-emerald-800'
    : diff === 1
    ? 'text-amber-400 bg-amber-900/30 border-amber-800'
    : 'text-red-400 bg-red-900/30 border-red-800'
  return (
    <div className="flex items-center gap-1.5">
      <span className="text-[10px] text-slate-400">
        <span>{renderTierLetters(tiersA)}</span> vs <span>{renderTierLetters(tiersB)}</span>
      </span>
      <span className={`text-[10px] px-1.5 py-0.5 rounded border font-medium ${color}`}>{badge}</span>
    </div>
  )
}

// ── Game card ────────────────────────────────────────────────────────────────

export function GameCard({
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
    <div className="bg-elevated border border-border rounded-xl px-3 py-2 flex flex-col gap-1.5">
      <div className="flex items-center justify-between">
        <span className="text-[10px] text-slate-400 font-medium">{courtName || `Court ${court + 1}`}</span>
        <TierBalance tiersA={tiersA} tiersB={tiersB} />
      </div>
      <div className="flex items-center gap-2">
        <div className="flex gap-1 flex-1 min-w-0 overflow-hidden">
          {teamA.map((id) => {
            const p = getPlayer(id)
            return p ? <PlayerChip key={id} player={p} backToBack={backToBackIds?.has(id)} /> : null
          })}
        </div>
        <span className="text-slate-400 text-xs font-bold shrink-0">vs</span>
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

// ── Schedule view ────────────────────────────────────────────────────────────

export function ScheduleView({
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

  const bySlot = new Map<number, ScheduleSlot[]>()
  for (const game of result.schedule) {
    const list = bySlot.get(game.slot) ?? []
    list.push(game)
    bySlot.set(game.slot, list)
  }

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
                    <span className="text-[10px] text-slate-400">sits out:</span>
                    {out.map((p) => (
                      <span key={p.id} className="text-[10px] text-slate-400 bg-slate-800/50 px-1.5 py-0.5 rounded">
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

      <div className="bg-surface border border-border-subtle rounded-2xl p-3 flex flex-col gap-2">
        <div className="flex items-center justify-between">
          <span className="text-sm font-semibold text-white">Player Stats</span>
          <span className="text-xs text-slate-400">target ~{idealPlays.toFixed(1)} plays</span>
        </div>
        <div className="grid grid-cols-1 gap-y-2">
          {(() => {
            const { playCount, sitCount, partnerWith, facedBy } = computePlayerStats(result.schedule, players.map(p => p.id))

            return players
              .sort((a, b) => (playCount[b.id] ?? 0) - (playCount[a.id] ?? 0))
              .map((p) => {
                const plays = playCount[p.id] ?? 0
                const sits = sitCount[p.id] ?? 0
                const partners = Object.keys(partnerWith[p.id] ?? {}).length
                const opponents = Object.keys(facedBy[p.id] ?? {}).length
                const over = plays > Math.ceil(idealPlays)
                const under = plays < Math.floor(idealPlays)
                return (
                  <div key={p.id} className="flex items-center gap-2">
                    <span className="text-xs text-slate-300 w-20 truncate">{p.name}</span>
                    <span className={`text-xs font-bold w-8 ${over ? 'text-amber-400' : under ? 'text-sky-400' : 'text-emerald-400'}`}>
                      {plays}×
                    </span>
                    <span className="text-[10px] text-slate-400">
                      {sits} sit · {partners} P · {opponents} O
                    </span>
                  </div>
                )
              })
          })()}
        </div>
        <p className="text-[10px] text-slate-400">P = unique partners · O = unique opponents faced</p>
      </div>
    </div>
  )
}

// ── Quality banner ───────────────────────────────────────────────────────────

export function QualityBanner({ result, playerMap, fixMatches, onRetryUntilGood, retryInfo }: {
  result: GeneratorResult
  playerMap: Map<string, Player>
  fixMatches: MatchConstraint[]
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
            <span className="text-[11px] text-slate-400">
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
            <span className="text-[11px] text-slate-400 shrink-0">{item.label}:</span>
            <span className={`text-[11px] font-medium truncate ${text[item.level]}`}>{item.detail}</span>
            {item.hint && (
              <span title={item.hint} className="text-[10px] text-slate-400 hover:text-slate-400 cursor-help shrink-0">ⓘ</span>
            )}
          </div>
        ))}
        <div className="col-span-2 flex items-center gap-1.5 min-w-0">
          <div className={`w-1.5 h-1.5 rounded-full shrink-0 ${dot[backToBackItem.level]}`} />
          <span className="text-[11px] text-slate-400 shrink-0">{backToBackItem.label}:</span>
          <span className={`text-[11px] font-medium ${text[backToBackItem.level]}`}>{backToBackItem.detail}</span>
        </div>
      </div>
    </div>
  )
}
