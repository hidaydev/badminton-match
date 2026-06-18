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

export interface TeamSwapTarget {
  slot: number
  court: number
  team: 'A' | 'B'
}

export function applyTeamSwap(
  schedule: ScheduleSlot[],
  t1: TeamSwapTarget,
  t2: TeamSwapTarget,
): ScheduleSlot[] {
  const game1 = schedule.find(s => s.slot === t1.slot && s.court === t1.court)
  const game2 = schedule.find(s => s.slot === t2.slot && s.court === t2.court)
  if (!game1 || !game2) return schedule

  const team1Players = t1.team === 'A' ? game1.teamA : game1.teamB
  const team2Players = t2.team === 'A' ? game2.teamA : game2.teamB

  return schedule.map(s => {
    if (s.slot === t1.slot && s.court === t1.court) {
      return t1.team === 'A'
        ? { ...s, teamA: team2Players }
        : { ...s, teamB: team2Players }
    }
    if (s.slot === t2.slot && s.court === t2.court) {
      return t2.team === 'A'
        ? { ...s, teamA: team1Players }
        : { ...s, teamB: team1Players }
    }
    return s
  })
}

export function detectTeamSwapConflict(
  schedule: ScheduleSlot[],
  t1: TeamSwapTarget,
  t2: TeamSwapTarget,
): string | null {
  const game1 = schedule.find(s => s.slot === t1.slot && s.court === t1.court)
  const game2 = schedule.find(s => s.slot === t2.slot && s.court === t2.court)
  if (!game1 || !game2) return null

  const team1Players = t1.team === 'A' ? [...game1.teamA] : [...game1.teamB]
  const team1Other = t1.team === 'A' ? [...game1.teamB] : [...game1.teamA]
  const team2Players = t2.team === 'A' ? [...game2.teamA] : [...game2.teamB]
  const team2Other = t2.team === 'A' ? [...game2.teamB] : [...game2.teamA]

  for (const pid of team1Players) {
    if (team2Other.includes(pid)) return pid
  }
  for (const pid of team2Players) {
    if (team1Other.includes(pid)) return pid
  }

  return null
}
