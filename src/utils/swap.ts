import type { ScheduleSlot, PlayerId, Player } from '../types'
import { toPlayerId } from '../types'

export interface SwapTarget {
  slot: number
  court: number
  playerId: string
  team: 'A' | 'B'
  index: 0 | 1
}

/** @deprecated Use SwapTarget instead — identical fields. */
export type ChangeTarget = SwapTarget

export function applyChange(
  schedule: ScheduleSlot[],
  target: ChangeTarget,
  newName: string,
): ScheduleSlot[] {
  // Only change the specific position in the target game, not all occurrences
  return schedule.map(s => {
    if (s.slot !== target.slot || s.court !== target.court) return s
    const teamA = [...s.teamA] as [PlayerId, PlayerId]
    const teamB = [...s.teamB] as [PlayerId, PlayerId]
    if (target.team === 'A') teamA[target.index] = toPlayerId(newName)
    else teamB[target.index] = toPlayerId(newName)
    return { ...s, teamA, teamB }
  })
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
      const teamA = [...s.teamA] as [PlayerId, PlayerId]
      const teamB = [...s.teamB] as [PlayerId, PlayerId]
      if (t1.team === 'A') teamA[t1.index] = toPlayerId(t2.playerId)
      else teamB[t1.index] = toPlayerId(t2.playerId)
      if (sameGame) {
        if (t2.team === 'A') teamA[t2.index] = toPlayerId(t1.playerId)
        else teamB[t2.index] = toPlayerId(t1.playerId)
      }
      return { ...s, teamA, teamB }
    }
    if (!sameGame && s.slot === t2.slot && s.court === t2.court) {
      const teamA = [...s.teamA] as [PlayerId, PlayerId]
      const teamB = [...s.teamB] as [PlayerId, PlayerId]
      if (t2.team === 'A') teamA[t2.index] = toPlayerId(t1.playerId)
      else teamB[t2.index] = toPlayerId(t1.playerId)
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

  const team1Players = [...(t1.team === 'A' ? game1.teamA : game1.teamB)] as [PlayerId, PlayerId]
  const team2Players = [...(t2.team === 'A' ? game2.teamA : game2.teamB)] as [PlayerId, PlayerId]
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

/**
 * Validate a player name change in a specific game slot.
 * Checks for same-game conflict, cross-slot conflict, and back-to-back warning.
 */
export function validateChangeName(
  target: ChangeTarget,
  name: string,
  schedule: ScheduleSlot[],
  playerMap: Map<string, Player>,
): { error: string | null; b2b: boolean } {
  // Same-game conflict: compare new name against other players' NAMES in this game
  const game = schedule.find(g => g.slot === target.slot && g.court === target.court)
  const otherNames = game
    ? [...game.teamA, ...game.teamB]
        .filter(id => id !== target.playerId)
        .map(id => playerMap.get(id)?.name ?? id)
    : []
  if (otherNames.some(n => n.toLowerCase() === name.toLowerCase())) {
    return { error: `${name} is already in this game`, b2b: false }
  }
  // Cross-slot: does the new name already play in another game this slot?
  const slotNames = new Set<string>()
  for (const g of schedule) {
    if (g.slot === target.slot && !(g.court === target.court)) {
      for (const id of [...g.teamA, ...g.teamB]) {
        slotNames.add((playerMap.get(id)?.name ?? id).toLowerCase())
      }
    }
  }
  if (slotNames.has(name.toLowerCase())) {
    return { error: `${name} already plays in another game this slot`, b2b: false }
  }
  // B2B: does the new name play in adjacent slots?
  const b2bNames = new Set<string>()
  for (const g of schedule) {
    if (g.slot === target.slot - 1 || g.slot === target.slot + 1) {
      for (const id of [...g.teamA, ...g.teamB]) {
        b2bNames.add((playerMap.get(id)?.name ?? id).toLowerCase())
      }
    }
  }
  const b2b = b2bNames.has(name.toLowerCase())
  return { error: null, b2b }
}
