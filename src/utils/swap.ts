import type { ScheduleSlot } from '../store'

export interface SwapTarget {
  slot: number
  court: number
  playerId: string
  team: 'A' | 'B'
  index: 0 | 1
}

export function applySwap(
  schedule: ScheduleSlot[],
  t1: SwapTarget,
  t2: SwapTarget,
): ScheduleSlot[] {
  const sameGame = t1.slot === t2.slot && t1.court === t2.court
  return schedule.map((s) => {
    if (s.slot === t1.slot && s.court === t1.court) {
      const teamA = [...s.teamA] as [string, string]
      const teamB = [...s.teamB] as [string, string]
      if (t1.team === 'A') teamA[t1.index] = t2.playerId
      else teamB[t1.index] = t2.playerId
      if (sameGame) {
        if (t2.team === 'A') teamA[t2.index] = t1.playerId
        else teamB[t2.index] = t1.playerId
      }
      return { ...s, teamA, teamB }
    }
    if (!sameGame && s.slot === t2.slot && s.court === t2.court) {
      const teamA = [...s.teamA] as [string, string]
      const teamB = [...s.teamB] as [string, string]
      if (t2.team === 'A') teamA[t2.index] = t1.playerId
      else teamB[t2.index] = t1.playerId
      return { ...s, teamA, teamB }
    }
    return s
  })
}
