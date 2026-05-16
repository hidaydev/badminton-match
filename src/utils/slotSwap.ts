import type { ScheduleSlot } from '../store'

export interface SlotSwapTarget {
  slot: number
  court: number
}

export function applySlotSwap(
  schedule: ScheduleSlot[],
  g1: SlotSwapTarget,
  g2: SlotSwapTarget,
): ScheduleSlot[] {
  return schedule.map((s) => {
    if (s.slot === g1.slot && s.court === g1.court) return { ...s, slot: g2.slot, court: g2.court }
    if (s.slot === g2.slot && s.court === g2.court) return { ...s, slot: g1.slot, court: g1.court }
    return s
  })
}

export function detectSlotSwapConflict(
  schedule: ScheduleSlot[],
  g1: SlotSwapTarget,
  g2: SlotSwapTarget,
): string | null {
  const game1 = schedule.find((s) => s.slot === g1.slot && s.court === g1.court)
  const game2 = schedule.find((s) => s.slot === g2.slot && s.court === g2.court)
  if (!game1 || !game2) return null

  const game1Players = [...game1.teamA, ...game1.teamB]
  const game2Players = [...game2.teamA, ...game2.teamB]

  // game1 moves to g2's slot — check others in that slot (excluding game2 itself)
  for (const other of schedule.filter((s) => s.slot === g2.slot && s.court !== g2.court)) {
    const otherPlayers = [...other.teamA, ...other.teamB]
    for (const pid of game1Players) {
      if (otherPlayers.includes(pid)) return pid
    }
  }

  // game2 moves to g1's slot — check others in that slot (excluding game1 itself)
  for (const other of schedule.filter((s) => s.slot === g1.slot && s.court !== g1.court)) {
    const otherPlayers = [...other.teamA, ...other.teamB]
    for (const pid of game2Players) {
      if (otherPlayers.includes(pid)) return pid
    }
  }

  return null
}
