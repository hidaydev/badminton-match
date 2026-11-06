import { describe, expect, it } from 'vitest'
import { computeStandings } from '../standings'
import { toGameKey, toPlayerId } from '../../types'
import type { GameKey, GameScore, Player, ScheduleSlot } from '../../types'

/**
 * One skipped game must not add a game to that player's row, but the opposing
 * side still gets the result. The same numbers come out of `session/standings`
 * on the server, which is what the shared link and the Instagram export use.
 */
describe('computeStandings', () => {
  const player = (id: string, name: string): Player => ({
    id: toPlayerId(id),
    name,
    gender: 'M',
    tier: 2,
  })

  const lulud = player('p-lulud', 'Lulud')
  const ani = player('p-ani', 'Ani')
  const budi = player('p-budi', 'Budi')
  const candra = player('p-candra', 'Candra')
  const dewi = player('p-dewi', 'Dewi')

  const game = (
    slot: number,
    court: number,
    teamA: Player[],
    teamB: Player[],
  ): ScheduleSlot => ({
    slot,
    court,
    teamA: [teamA[0].id, teamA[1].id],
    teamB: [teamB[0].id, teamB[1].id],
  })

  const schedule = [
    game(0, 0, [lulud, ani], [budi, candra]),
    game(2, 0, [lulud, budi], [ani, candra]),
    game(3, 0, [lulud, candra], [ani, budi]),
    // The skipped one: Lulud sits this game out, the other three still play it.
    game(6, 1, [lulud, dewi], [ani, budi]),
  ]

  const score = (a: number, b: number): GameScore => ({ a, b })
  const gameScores: Record<GameKey, GameScore> = {
    [toGameKey(0, 0)]: score(30, 24),
    [toGameKey(2, 0)]: score(30, 12),
    [toGameKey(3, 0)]: score(30, 12),
    [toGameKey(6, 1)]: score(30, 18),
  }

  const standings = computeStandings(
    [lulud, ani, budi, candra, dewi],
    schedule,
    gameScores,
    [],
    { [toGameKey(6, 1)]: [lulud.id] },
  )

  const row = (name: string) => standings.find((entry) => entry.player.name === name)!

  it('drops the skipped player from that game only', () => {
    expect(row('Lulud').wins).toBe(3)
    expect(row('Lulud').losses).toBe(0)
    expect(row('Lulud').pointsFor).toBe(90)
    expect(row('Lulud').pointsAgainst).toBe(48)
  })

  it('still counts the game for the other three players', () => {
    // Ani and Budi lost the skipped game; the skip only removes Lulud.
    expect(row('Budi').wins + row('Budi').losses).toBe(4)
    expect(row('Ani').wins + row('Ani').losses).toBe(4)
    expect(row('Dewi').wins + row('Dewi').losses).toBe(1)
  })

  it('orders by wins, then point difference, then points for', () => {
    expect(standings.map((entry) => entry.player.name)).toEqual([
      'Lulud',
      'Dewi',
      'Candra',
      'Budi',
      'Ani',
    ])
  })
})