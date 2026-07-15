import type { ScheduleSlot } from '../store'

export interface SwapTarget {
  slot: number
  court: number
  playerId: string
  team: 'A' | 'B'
  index: 0 | 1
}

export interface ChangeTarget {
  slot: number
  court: number
  team: 'A' | 'B'
  index: 0 | 1
}

export function applyChange(
  schedule: ScheduleSlot[],
  target: ChangeTarget,
  newName: string,
): ScheduleSlot[] {
  // Early return if replacement is same as current player
  const game = schedule.find(s => s.slot === target.slot && s.court === target.court)
  if (game) {
    const currentId = target.team === 'A' ? game.teamA[target.index] : game.teamB[target.index]
    if (currentId === newName) return schedule
  }
  return schedule.map(s => {
    if (s.slot !== target.slot || s.court !== target.court) return s
    const teamA = [...s.teamA] as [string, string]
    const teamB = [...s.teamB] as [string, string]
    if (target.team === 'A') teamA[target.index] = newName
    else teamB[target.index] = newName
    return { ...s, teamA, teamB }
  })
}

export function detectChangeConflict(
  schedule: ScheduleSlot[],
  target: ChangeTarget,
  newName: string,
): string | null {
  const game = schedule.find(s => s.slot === target.slot && s.court === target.court)
  if (!game) return null
  // Exclude the player being replaced from conflict check
  const otherPlayers = [...game.teamA, ...game.teamB].filter((_, i) => {
    const team = i < 2 ? 'A' : 'B'
    const idx = i % 2
    return !(team === target.team && idx === target.index)
  })
  if (otherPlayers.includes(newName)) return newName
  return null
}

export function applySwap(
  schedule: ScheduleSlot[],
  t1: SwapTarget,
  t2: SwapTarget,
): ScheduleSlot[] {
  // Early return if same position
  if (t1.slot === t2.slot && t1.court === t2.court && t1.team === t2.team && t1.index === t2.index) return schedule
  // Early return if same player (no-op swap)
  if (t1.playerId === t2.playerId) return schedule

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
  // Early return if same team in same game
  if (t1.slot === t2.slot && t1.court === t2.court && t1.team === t2.team) return schedule

  const game1 = schedule.find(s => s.slot === t1.slot && s.court === t1.court)
  const game2 = schedule.find(s => s.slot === t2.slot && s.court === t2.court)
  if (!game1 || !game2) return schedule

  const team1Players = [...(t1.team === 'A' ? game1.teamA : game1.teamB)] as [string, string]
  const team2Players = [...(t2.team === 'A' ? game2.teamA : game2.teamB)] as [string, string]
  const sameGame = t1.slot === t2.slot && t1.court === t2.court

  return schedule.map(s => {
    if (s.slot === t1.slot && s.court === t1.court) {
      const updated = { ...s }
      if (t1.team === 'A') updated.teamA = team2Players
      else updated.teamB = team2Players
      if (sameGame) {
        if (t2.team === 'A') updated.teamA = team1Players
        else updated.teamB = team1Players
      }
      return updated
    }
    if (!sameGame && s.slot === t2.slot && s.court === t2.court) {
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

  // Same-game swap (Team A ↔ Team B of the same game) is always valid — no conflict possible
  if (t1.slot === t2.slot && t1.court === t2.court) return null

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
