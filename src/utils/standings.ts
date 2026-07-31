import type { Player, ScheduleSlot, GameScore, GameKey } from '../types'
import { toGameKey } from '../types'
import { initTallyRow, tallyMatch, computeDiff, standardStandingSort, type TallyRow } from './tally'

export interface PlayerStanding extends TallyRow {
  player: Player
}

export function computeStandings(
  players: Player[],
  schedule: ScheduleSlot[],
  gameScores: Record<GameKey, GameScore>,
): PlayerStanding[] {
  const map = new Map<string, PlayerStanding>()

  for (const p of players) {
    map.set(p.id, { ...initTallyRow(), player: p })
  }

  for (const slot of schedule) {
    const key = toGameKey(slot.slot, slot.court)
    const score = gameScores[key]
    if (!score) continue

    const { a, b } = score

    for (const id of slot.teamA) {
      const standing = map.get(id)
      if (standing) tallyMatch(standing, a, b)
    }

    for (const id of slot.teamB) {
      const standing = map.get(id)
      if (standing) tallyMatch(standing, b, a)
    }
  }

  for (const standing of map.values()) computeDiff(standing)

  return [...map.values()].sort((a, b) =>
    standardStandingSort(a, b) || a.player.name.localeCompare(b.player.name)
  )
}
