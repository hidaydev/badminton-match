import type { ScheduleSlot } from '../types'
import { bumpCoOccurrence } from './counter'

/**
 * Compute play count, sit count, partner co-occurrence, and opponent
 * co-occurrence for a set of players over a schedule.
 */
export function computePlayerStats(
  schedule: ScheduleSlot[],
  playerIds: string[],
): {
  playCount: Record<string, number>
  sitCount: Record<string, number>
  partnerWith: Record<string, Record<string, number>>
  facedBy: Record<string, Record<string, number>>
} {
  const playCount: Record<string, number> = Object.fromEntries(playerIds.map((id) => [id, 0]))
  const partnerWith: Record<string, Record<string, number>> = {}
  const facedBy: Record<string, Record<string, number>> = {}

  for (const g of schedule) {
    for (const id of [...g.teamA, ...g.teamB]) playCount[id]++
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
  const sitCount: Record<string, number> = Object.fromEntries(playerIds.map((id) => [id, 0]))
  for (let t = 0; t < maxSlots; t++) {
    const playing = slotPlayerSet.get(t) ?? new Set<string>()
    for (const id of playerIds) {
      if (!playing.has(id)) sitCount[id]++
    }
  }

  return { playCount, sitCount, partnerWith, facedBy }
}
