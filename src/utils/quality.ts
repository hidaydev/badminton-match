// src/utils/quality.ts
// Schedule quality analysis — pure domain logic, no React dependencies.

import type { Player, MatchConstraint } from '../types'
import type { GeneratorResult } from '../generator'

export interface QualityMetrics {
  playSpread: number
  minPlays: number
  maxPlays: number
  unevenGames: number
  backToBackCount: number
  backToBackFloor: number
  repeatedPairs: number
  excludedPairs: number
  repeatedOpponents: number
  excludedOpponents: number
  totalGames: number
}

export function computeQuality(
  result: GeneratorResult,
  playerMap: Map<string, Player>,
  fixMatches: MatchConstraint[],
): QualityMetrics | null {
  const players = [...playerMap.values()]
  if (players.length === 0 || result.schedule.length === 0) return null

  const plays = players.map((p) => result.playCount[p.id] ?? 0)
  const minPlays = Math.min(...plays)
  const maxPlays = Math.max(...plays)

  let unevenGames = 0
  for (const g of result.schedule) {
    const tierA = (playerMap.get(g.teamA[0])?.tier ?? 5) + (playerMap.get(g.teamA[1])?.tier ?? 5)
    const tierB = (playerMap.get(g.teamB[0])?.tier ?? 5) + (playerMap.get(g.teamB[1])?.tier ?? 5)
    if (Math.abs(tierA - tierB) >= 2) unevenGames++
  }

  const slotPlayers = new Map<number, Set<string>>()
  const courtsPerSlot = new Map<number, number>()
  for (const g of result.schedule) {
    const set = slotPlayers.get(g.slot) ?? new Set<string>()
    g.teamA.forEach((id) => set.add(id))
    g.teamB.forEach((id) => set.add(id))
    slotPlayers.set(g.slot, set)
    courtsPerSlot.set(g.slot, Math.max(courtsPerSlot.get(g.slot) ?? 0, g.court + 1))
  }
  const slots = [...slotPlayers.keys()].sort((a, b) => a - b)
  let backToBackCount = 0
  let backToBackFloor = 0
  for (let i = 0; i < slots.length - 1; i++) {
    if (slots[i + 1] !== slots[i] + 1) continue
    const cur = slotPlayers.get(slots[i])!
    const nxt = slotPlayers.get(slots[i + 1])!
    for (const id of cur) if (nxt.has(id)) backToBackCount++
    // Mathematical minimum overlap between consecutive slots: players playing in
    // both slots must be at least (players needed in both) − (total players).
    // Each court contributes 4 players, so: max(0, 4·(Ci + Cj) − P).
    // Verified empirically against the generator (see HANDOFF §3b).
    const forcedOverlap = 4 * (courtsPerSlot.get(slots[i])! + courtsPerSlot.get(slots[i + 1])!) - players.length
    if (forcedOverlap > 0) backToBackFloor += forcedOverlap
  }

  const fixForcedPairs: Record<string, number> = {}
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

  return { playSpread: maxPlays - minPlays, minPlays, maxPlays, unevenGames, backToBackCount, backToBackFloor, repeatedPairs, excludedPairs, repeatedOpponents, excludedOpponents, totalGames: result.schedule.length }
}

export function qualityScore(
  result: GeneratorResult,
  playerMap: Map<string, Player>,
  fixMatches: MatchConstraint[],
): number {
  const q = computeQuality(result, playerMap, fixMatches)
  if (!q) return Infinity
  return q.playSpread * 10 + q.unevenGames * 2 + q.repeatedPairs * 3
}

/**
 * Whether the generator produced a fair schedule (play spread, match balance,
 * partner variety).
 *
 * `backToBackCount` is intentionally NOT part of this check: for tight
 * configurations (e.g. 8P-2C, 12P-2C, 16P-3C) back-to-back games are a
 * mathematical lower bound that retrying cannot reduce — marking them "not
 * good" here would make the retry loop burn all attempts without improvement.
 * The UI surfaces unavoidable back-to-back via `QualityBanner` instead
 * (compare `backToBackCount` against `backToBackFloor`).
 */
export function isGoodQuality(
  result: GeneratorResult,
  playerMap: Map<string, Player>,
  fixMatches: MatchConstraint[],
): boolean {
  const q = computeQuality(result, playerMap, fixMatches)
  if (!q) return false
  return q.playSpread <= 1 && q.unevenGames === 0 && q.repeatedPairs === 0
}
