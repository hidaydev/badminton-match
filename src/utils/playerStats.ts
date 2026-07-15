import type { ScheduleSlot } from '../store'

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

  const inc2 = (obj: Record<string, Record<string, number>>, a: string, b: string) => {
    obj[a] ??= {}; obj[a][b] = (obj[a][b] ?? 0) + 1
    obj[b] ??= {}; obj[b][a] = (obj[b][a] ?? 0) + 1
  }

  for (const g of schedule) {
    for (const id of [...g.teamA, ...g.teamB]) playCount[id]++
    inc2(partnerWith, g.teamA[0], g.teamA[1])
    inc2(partnerWith, g.teamB[0], g.teamB[1])
    for (const a of g.teamA) {
      for (const b of g.teamB) {
        facedBy[a] ??= {}; facedBy[a][b] = (facedBy[a][b] ?? 0) + 1
        facedBy[b] ??= {}; facedBy[b][a] = (facedBy[b][a] ?? 0) + 1
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
