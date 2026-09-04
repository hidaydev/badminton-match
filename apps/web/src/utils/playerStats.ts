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
 * Count how many times each player plays in consecutive (adjacent) slots.
 * Each boundary between two consecutive slots where the player appears in
 * both counts as 1 — same semantics as `backToBackCount` in quality.ts.
 * Example: playing slots 1-2-3 → count 2.
 */
export function computeBackToBackCounts(
  schedule: ScheduleSlot[],
  playerIds: string[],
): Record<PlayerId, number> {
  const counts = Object.fromEntries(playerIds.map((id) => [toPlayerId(id), 0])) as Record<PlayerId, number>

  const slotPlayerSet = new Map<number, Set<string>>()
  for (const g of schedule) {
    const set = slotPlayerSet.get(g.slot) ?? new Set<string>()
    g.teamA.forEach((id) => set.add(id))
    g.teamB.forEach((id) => set.add(id))
    slotPlayerSet.set(g.slot, set)
  }

  const slots = [...slotPlayerSet.keys()].sort((a, b) => a - b)
  for (let i = 0; i < slots.length - 1; i++) {
    if (slots[i + 1] !== slots[i] + 1) continue
    const cur = slotPlayerSet.get(slots[i])!
    const nxt = slotPlayerSet.get(slots[i + 1])!
    for (const id of cur) {
      if (nxt.has(id)) counts[toPlayerId(id)]++
    }
  }

  return counts
}
