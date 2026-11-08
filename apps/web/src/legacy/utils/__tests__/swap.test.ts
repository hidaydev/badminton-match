import { describe, expect, it } from 'vitest'
import {
  applySwap,
  applyTeamSwap,
  detectTeamSwapConflict,
  validateChangeName,
  type SwapTarget,
  type TeamSwapTarget,
} from '../swap'
import { toPlayerId } from '../../types'
import type { Player, ScheduleSlot } from '../../types'

const game = (
  slot: number,
  court: number,
  teamA: [string, string],
  teamB: [string, string],
): ScheduleSlot => ({
  slot,
  court,
  teamA: [toPlayerId(teamA[0]), toPlayerId(teamA[1])],
  teamB: [toPlayerId(teamB[0]), toPlayerId(teamB[1])],
})

const player = (id: string, name: string): Player => ({
  id: toPlayerId(id),
  name,
  gender: 'M',
  tier: 4,
})

describe('applySwap', () => {
  it('exchanges one position between two slots and leaves the other six players alone', () => {
    const schedule = [
      game(0, 0, ['p1', 'p2'], ['p3', 'p4']),
      game(0, 1, ['p5', 'p6'], ['p7', 'p8']),
    ]
    const from: SwapTarget = { slot: 0, court: 0, playerId: 'p1', team: 'A', index: 0 }
    const to: SwapTarget = { slot: 0, court: 1, playerId: 'p7', team: 'B', index: 0 }

    const result = applySwap(schedule, from, to)

    expect(result[0]).toEqual(game(0, 0, ['p7', 'p2'], ['p3', 'p4']))
    expect(result[1]).toEqual(game(0, 1, ['p5', 'p6'], ['p1', 'p8']))
    // The input schedule is not mutated.
    expect(schedule[0]).toEqual(game(0, 0, ['p1', 'p2'], ['p3', 'p4']))
    expect(schedule[1]).toEqual(game(0, 1, ['p5', 'p6'], ['p7', 'p8']))
  })

  it('swaps both positions inside one game', () => {
    const schedule = [game(0, 0, ['p1', 'p2'], ['p3', 'p4'])]
    const from: SwapTarget = { slot: 0, court: 0, playerId: 'p1', team: 'A', index: 0 }
    const to: SwapTarget = { slot: 0, court: 0, playerId: 'p3', team: 'B', index: 0 }

    expect(applySwap(schedule, from, to)[0]).toEqual(game(0, 0, ['p3', 'p2'], ['p1', 'p4']))
  })

  it('returns the schedule untouched for a same-position or same-player request', () => {
    const schedule = [game(0, 0, ['p1', 'p2'], ['p3', 'p4'])]
    const from: SwapTarget = { slot: 0, court: 0, playerId: 'p1', team: 'A', index: 0 }

    expect(applySwap(schedule, from, { ...from })).toBe(schedule)
    expect(applySwap(schedule, from, { ...from, index: 1 })).toBe(schedule)
  })
})

describe('applyTeamSwap', () => {
  it('exchanges whole sides and keeps the order inside each team', () => {
    const schedule = [
      game(0, 0, ['p1', 'p2'], ['p3', 'p4']),
      game(1, 0, ['p5', 'p6'], ['p7', 'p8']),
    ]
    const from: TeamSwapTarget = { slot: 0, court: 0, team: 'A' }
    const to: TeamSwapTarget = { slot: 1, court: 0, team: 'A' }

    const result = applyTeamSwap(schedule, from, to)

    expect(result[0]).toEqual(game(0, 0, ['p5', 'p6'], ['p3', 'p4']))
    expect(result[1]).toEqual(game(1, 0, ['p1', 'p2'], ['p7', 'p8']))
  })

  it('exchanges both sides of the same game', () => {
    const schedule = [game(0, 0, ['p1', 'p2'], ['p3', 'p4'])]
    const from: TeamSwapTarget = { slot: 0, court: 0, team: 'A' }
    const to: TeamSwapTarget = { slot: 0, court: 0, team: 'B' }

    expect(applyTeamSwap(schedule, from, to)[0]).toEqual(game(0, 0, ['p3', 'p4'], ['p1', 'p2']))
  })

  it('returns the schedule untouched when one of the games is missing', () => {
    const schedule = [
      game(0, 0, ['p1', 'p2'], ['p3', 'p4']),
      game(1, 0, ['p5', 'p6'], ['p7', 'p8']),
    ]

    expect(applyTeamSwap(schedule, { slot: 9, court: 0, team: 'A' }, { slot: 1, court: 0, team: 'A' })).toBe(
      schedule,
    )
  })
})

describe('detectTeamSwapConflict', () => {
  it('reports the player that the swap would duplicate, not a boolean', () => {
    // p1 and p2 are a fixed pair on court 0. Court 1 already sits p1 beside p7,
    // so moving court 0's side there would put p1 in both teams.
    const schedule = [
      game(0, 0, ['p1', 'p2'], ['p3', 'p4']),
      game(1, 0, ['p5', 'p6'], ['p1', 'p7']),
    ]

    const conflict = detectTeamSwapConflict(
      schedule,
      { slot: 0, court: 0, team: 'A' },
      { slot: 1, court: 0, team: 'A' },
    )

    expect(conflict).toBe('p1')
  })

  it('finds a collision coming from the incoming side too', () => {
    // p2 already sits on court 0's side A, so moving court 1's side B in would
    // put p2 on both sides of court 0.
    const schedule = [
      game(0, 0, ['p1', 'p2'], ['p3', 'p4']),
      game(1, 0, ['p5', 'p6'], ['p2', 'p7']),
    ]

    const conflict = detectTeamSwapConflict(
      schedule,
      { slot: 0, court: 0, team: 'B' },
      { slot: 1, court: 0, team: 'B' },
    )

    expect(conflict).toBe('p2')
  })

  it('returns null when the sides do not overlap, within one game, or on a missing game', () => {
    const schedule = [
      game(0, 0, ['p1', 'p2'], ['p3', 'p4']),
      game(1, 0, ['p5', 'p6'], ['p7', 'p8']),
    ]

    expect(
      detectTeamSwapConflict(schedule, { slot: 0, court: 0, team: 'A' }, { slot: 1, court: 0, team: 'A' }),
    ).toBeNull()
    expect(
      detectTeamSwapConflict(schedule, { slot: 0, court: 0, team: 'A' }, { slot: 0, court: 0, team: 'B' }),
    ).toBeNull()
    expect(
      detectTeamSwapConflict(schedule, { slot: 9, court: 0, team: 'A' }, { slot: 1, court: 0, team: 'A' }),
    ).toBeNull()
  })
})

describe('validateChangeName', () => {
  const players = [
    player('p1', 'Arya'),
    player('p2', 'Bowo'),
    player('p3', 'Candra'),
    player('p4', 'Dika'),
    player('p5', 'Eka'),
    player('p6', 'Fajar'),
    player('p7', 'Gita'),
    player('p8', 'Hana'),
    player('p9', 'Iwan'),
  ]
  const playerMap = new Map(players.map((p) => [p.id as string, p]))
  const schedule = [
    game(0, 0, ['p1', 'p2'], ['p3', 'p4']),
    game(0, 1, ['p5', 'p6'], ['p7', 'p8']),
    game(1, 0, ['p1', 'p5'], ['p2', 'p9']),
  ]
  const target: SwapTarget = { slot: 0, court: 0, playerId: 'p1', team: 'A', index: 0 }

  it('rejects a name already playing in the same game, ignoring case', () => {
    expect(validateChangeName(target, 'bowo', schedule, playerMap)).toEqual({
      error: 'bowo is already in this game',
      b2b: false,
    })
  })

  it('rejects a name that already plays another court in the same slot', () => {
    expect(validateChangeName(target, 'Gita', schedule, playerMap)).toEqual({
      error: 'Gita already plays in another game this slot',
      b2b: false,
    })
  })

  it('flags a back-to-back name without an error', () => {
    expect(validateChangeName(target, 'Iwan', schedule, playerMap)).toEqual({ error: null, b2b: true })
  })

  it('accepts a name that is not on the schedule at all', () => {
    expect(validateChangeName(target, 'Zaki', schedule, playerMap)).toEqual({ error: null, b2b: false })
  })
})