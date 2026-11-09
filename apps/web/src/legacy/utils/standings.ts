import type { Player, ScheduleSlot, GameScore, GameKey } from '../types'
import { toGameKey } from '../types'
import { initTallyRow, tallyMatch, computeDiff, standardStandingSort, type TallyRow } from './tally'
import { setsWon } from './scoring'

export interface PlayerStanding extends TallyRow {
  player: Player
}

export function computeStandings(
  players: Player[],
  schedule: ScheduleSlot[],
  gameScores: Record<GameKey, GameScore>,
  voidPlayerIds?: Iterable<string>,
  skippedPlayers?: Record<string, string[]>,
  playedGames?: string[],
): PlayerStanding[] {
  const map = new Map<string, PlayerStanding>()
  // skip_player semantics (MIRRORS the rating engine, domain.MatchRateable):
  // a game with absent/skipped players still counts for the players who
  // actually played; only void players (absent/placeholder) are excluded from
  // the tally. A per-game skip is added as a void for that game (union with the
  // global void set).
  //
  // A team MAY be empty in the tally as long as it still has a real player: the
  // real case is "two players skipped", where they were replaced by others and
  // the score still stands, so the opposing team keeps the game. A game is
  // dropped when either side has no real player at all (for example all
  // placeholders or globally absent), or when both teams have no eligible
  // player (for example every player skipped).
  const voidSet = voidPlayerIds ? new Set(voidPlayerIds) : null
  // The real players present. The caller's `players` list already excludes
  // globally absent players and placeholders; players skipped for one game are
  // still here (they attended, they were only replaced in that game).
  const realIds = new Set<string>(players.map((p) => p.id))
  // A partial match has sets but is not a result yet; the server reports that as
  // `scheduled`, and only the played list is tallied.
  const playedSet = playedGames ? new Set(playedGames) : null

  for (const p of players) {
    map.set(p.id, { ...initTallyRow(), player: p })
  }

  for (const slot of schedule) {
    const key = toGameKey(slot.slot, slot.court)
    if (playedSet !== null && !playedSet.has(key)) continue
    const score = gameScores[key]
    if (!score) continue

    // Per-game skipped union
    let skipSet: Set<string> | null = null
    if (skippedPlayers?.[key]?.length) skipSet = new Set(skippedPlayers[key])

    const teamA = (() => {
      const skip = skipSet
      let a = voidSet ? slot.teamA.filter((id) => !voidSet.has(id)) : [...slot.teamA]
      if (skip !== null) a = a.filter((id) => !skip.has(id))
      return a
    })()
    const teamB = (() => {
      const skip = skipSet
      let b = voidSet ? slot.teamB.filter((id) => !voidSet.has(id)) : [...slot.teamB]
      if (skip !== null) b = b.filter((id) => !skip.has(id))
      return b
    })()
    // No real player on one side (all placeholders/absent), so drop the game.
    if (!slot.teamA.some((id) => realIds.has(id)) || !slot.teamB.some((id) => realIds.has(id))) continue
    // Both sides are empty after void/skip, so there is nothing to tally.
    if (teamA.length === 0 && teamB.length === 0) continue

    const { a, b } = score
    // A multi-set format is decided by sets won; total points only break the
    // board's tie-breaks. Single games fall back to the point comparison.
    const won = score.sets && score.sets.length > 0
      ? setsWon(score.sets)
      : null

    for (const id of teamA) {
      const standing = map.get(id)
      if (standing) tallyMatch(standing, a, b, won ? won.a > won.b : undefined)
    }

    for (const id of teamB) {
      const standing = map.get(id)
      if (standing) tallyMatch(standing, b, a, won ? won.b > won.a : undefined)
    }
  }

  for (const standing of map.values()) computeDiff(standing)

  return [...map.values()].sort((a, b) =>
    standardStandingSort(a, b) || a.player.name.localeCompare(b.player.name)
  )
}
