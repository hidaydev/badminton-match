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
  voidPlayerIds?: Iterable<string>,
  skippedPlayers?: Record<string, string[]>,
): PlayerStanding[] {
  const map = new Map<string, PlayerStanding>()
  // Semantik skip_player (konsisten dengan rating engine, rating.go):
  // game dengan pemain absent TETAP dihitung untuk pemain yang benar-benar
  // main — hanya pemain void (absent/placeholder) yang di-exclude dari tally.
  // Skip per-game ditambah sebagai void per game (union dengan global void).
  // Game di-skip hanya jika salah satu tim tidak punya pemain aktif sama sekali.
  const voidSet = voidPlayerIds ? new Set(voidPlayerIds) : null

  for (const p of players) {
    map.set(p.id, { ...initTallyRow(), player: p })
  }

  for (const slot of schedule) {
    const key = toGameKey(slot.slot, slot.court)
    const score = gameScores[key]
    if (!score) continue

    // Per-game skipped union
    let skipSet: Set<string> | null = null
    if (skippedPlayers?.[key]?.length) skipSet = new Set(skippedPlayers[key])

    const teamA = (() => {
      let a = voidSet ? slot.teamA.filter((id) => !voidSet.has(id)) : [...slot.teamA]
      if (skipSet) a = a.filter((id) => !skipSet!.has(id))
      return a
    })()
    const teamB = (() => {
      let b = voidSet ? slot.teamB.filter((id) => !voidSet.has(id)) : [...slot.teamB]
      if (skipSet) b = b.filter((id) => !skipSet!.has(id))
      return b
    })()
    // Tim tanpa pemain aktif → game tidak valid untuk siapa pun
    if (teamA.length === 0 || teamB.length === 0) continue

    const { a, b } = score

    for (const id of teamA) {
      const standing = map.get(id)
      if (standing) tallyMatch(standing, a, b)
    }

    for (const id of teamB) {
      const standing = map.get(id)
      if (standing) tallyMatch(standing, b, a)
    }
  }

  for (const standing of map.values()) computeDiff(standing)

  return [...map.values()].sort((a, b) =>
    standardStandingSort(a, b) || a.player.name.localeCompare(b.player.name)
  )
}
