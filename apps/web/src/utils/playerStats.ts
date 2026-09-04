import type { ScheduleSlot, PlayerId } from '../types'
import { toPlayerId } from '../types'
import { bumpCoOccurrence } from './counter'

/**
 * Compute play count, sit count, partner co-occurrence, and opponent
 * co-occurrence for a set of players over a schedule.
 */
export function computePlayerStats(
  schedule: ScheduleSlot[],
  playerIds: string[],
): {
  playCount: Record<PlayerId, number>
  sitCount: Record<PlayerId, number>
  partnerWith: Record<PlayerId, Record<PlayerId, number>>
  facedBy: Record<PlayerId, Record<PlayerId, number>>
} {
  const playCount = Object.fromEntries(playerIds.map((id) => [toPlayerId(id), 0])) as Record<PlayerId, number>
  const partnerWith = {} as Record<PlayerId, Record<PlayerId, number>>
  const facedBy = {} as Record<PlayerId, Record<PlayerId, number>>

  for (const g of schedule) {
    for (const id of [...g.teamA, ...g.teamB]) playCount[toPlayerId(id)]++
    bumpCoOccurrence(partnerWith, g.teamA[0], g.teamA[1])
    bumpCoOccurrence(partnerWith, g.teamB[0], g.teamB[1])
    for (const a of g.teamA) {
      for (const b of g.teamB) {
        bumpCoOccurrence(facedBy, a, b)
      }
    }
  }

  // Compute sit count
  const slotPlayerSet = new Map<number, Set<string>>()
  for (const g of schedule) {
    const set = slotPlayerSet.get(g.slot) ?? new Set<string>()
    g.teamA.forEach((id) => set.add(id)); g.teamB.forEach((id) => set.add(id))
    slotPlayerSet.set(g.slot, set)
  }
  const maxSlots = schedule.length > 0 ? Math.max(...schedule.map((g) => g.slot)) + 1 : 0
  const sitCount = Object.fromEntries(playerIds.map((id) => [toPlayerId(id), 0])) as Record<PlayerId, number>
  for (let t = 0; t < maxSlots; t++) {
    const playing = slotPlayerSet.get(t) ?? new Set<string>()
    for (const id of playerIds) {
      if (!playing.has(id)) sitCount[toPlayerId(id)]++
    }
  }

  return { playCount, sitCount, partnerWith, facedBy }
}

/**
 * Compute back-to-back run length for every game slot of each player: a chip
 * whose slot is inside a maximal run of k consecutive slots gets k. So a player
 * playing 1-2-3 has {1:3, 2:3, 3:3} (each of the three games is part of the
 * run), while playing 1-2 and 6-7 yields {1:2, 2:2, 6:2, 7:2} and a lone game
 * at 4 (or 4 alone) is absent — only games that are genuinely part of a
 * back-to-back run get marked.
 *
 * This is the chip-display semantics ("games played without rest") and
 * intentionally differs from `backToBackCount` in quality.ts, which counts
 * slot boundaries (1-2-3 → 2) for the aggregate QualityBanner metric.
 */
export function computeBackToBackRunBySlot(
  schedule: ScheduleSlot[],
  playerIds: string[],
): Record<PlayerId, Map<number, number>> {
  const byPlayer = Object.fromEntries(playerIds.map((id) => [toPlayerId(id), new Map<number, number>()])) as Record<PlayerId, Map<number, number>>

  const playerSlots = new Map<string, Set<number>>()
  for (const g of schedule) {
    for (const id of [...g.teamA, ...g.teamB]) {
      const set = playerSlots.get(id) ?? new Set<number>()
      set.add(g.slot)
      playerSlots.set(id, set)
    }
  }

  for (const id of playerIds) {
    const pid = toPlayerId(id)
    const slots = [...(playerSlots.get(id) ?? [])].sort((a, b) => a - b)
    let i = 0
    while (i < slots.length) {
      let j = i
      while (j + 1 < slots.length && slots[j + 1] === slots[j] + 1) j++
      const run = j - i + 1
      if (run >= 2) {
        const map = byPlayer[pid]
        for (let k = i; k <= j; k++) map.set(slots[k], run)
      }
      i = j + 1
    }
  }

  return byPlayer
}
