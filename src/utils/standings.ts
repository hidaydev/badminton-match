import type { Player, ScheduleSlot, GameScore } from '../store'

export interface PlayerStanding {
  player: Player
  wins: number
  losses: number
  pointsFor: number
  pointsAgainst: number
  diff: number
}

export function computeStandings(
  players: Player[],
  schedule: ScheduleSlot[],
  gameScores: Record<string, GameScore>,
): PlayerStanding[] {
  const map = new Map<string, PlayerStanding>()

  for (const p of players) {
    map.set(p.id, { player: p, wins: 0, losses: 0, pointsFor: 0, pointsAgainst: 0, diff: 0 })
  }

  for (const slot of schedule) {
    const key = `${slot.slot}-${slot.court}`
    const score = gameScores[key]
    if (!score) continue

    const { a, b } = score
    const teamAWon = a > b

    for (const id of slot.teamA) {
      const s = map.get(id)
      if (!s) continue
      if (teamAWon) {
        s.wins++
      } else {
        s.losses++
      }
      s.pointsFor += a
      s.pointsAgainst += b
    }

    for (const id of slot.teamB) {
      const s = map.get(id)
      if (!s) continue
      if (!teamAWon) {
        s.wins++
      } else {
        s.losses++
      }
      s.pointsFor += b
      s.pointsAgainst += a
    }
  }

  for (const s of map.values()) {
    s.diff = s.pointsFor - s.pointsAgainst
  }

  return [...map.values()].sort((a, b) => {
    if (b.wins !== a.wins) return b.wins - a.wins
    if (b.diff !== a.diff) return b.diff - a.diff
    return b.pointsFor - a.pointsFor
  })
}
