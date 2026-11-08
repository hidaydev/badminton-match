import { describe, expect, it } from 'vitest'
import { computeBackToBackRunBySlot, computePlayerStats } from '../playerStats'
import { toPlayerId } from '../../types'
import type { ScheduleSlot } from '../../types'

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

const ids = ['p1', 'p2', 'p3', 'p4', 'p5', 'p6', 'p7']

describe('computePlayerStats', () => {
  // p1 plays every game, including both courts of slot 2.
  const schedule = [
    game(0, 0, ['p1', 'p2'], ['p3', 'p4']),
    game(1, 0, ['p5', 'p6'], ['p7', 'p1']),
    game(2, 0, ['p1', 'p2'], ['p3', 'p4']),
    game(2, 1, ['p1', 'p5'], ['p6', 'p7']),
  ]

  const stats = computePlayerStats(schedule, ids)
  const byId = (record: Record<string, number>, id: string) => record[toPlayerId(id)]

  it('counts a sit for every listed player missing from a slot', () => {
    // Slot 0: p5, p6, p7 sit. Slot 1: p2, p3, p4 sit. Slot 2: everyone plays.
    expect(ids.map((id) => byId(stats.sitCount, id))).toEqual([0, 1, 1, 1, 1, 1, 1])
  })

  it('gives no sit to a player who appears in both games of one slot', () => {
    expect(byId(stats.sitCount, 'p1')).toBe(0)
    expect(byId(stats.playCount, 'p1')).toBe(4)
  })

  it('counts games played per player', () => {
    expect(ids.map((id) => byId(stats.playCount, id))).toEqual([4, 2, 2, 2, 2, 2, 2])
  })

  it('counts partners symmetrically and opponents across both teams', () => {
    expect(stats.partnerWith[toPlayerId('p1')][toPlayerId('p2')]).toBe(2)
    expect(stats.partnerWith[toPlayerId('p2')][toPlayerId('p1')]).toBe(2)
    expect(stats.partnerWith[toPlayerId('p1')][toPlayerId('p5')]).toBe(1)
    expect(stats.facedBy[toPlayerId('p1')][toPlayerId('p3')]).toBe(2)
    expect(stats.facedBy[toPlayerId('p3')][toPlayerId('p1')]).toBe(2)
    expect(stats.facedBy[toPlayerId('p1')][toPlayerId('p6')]).toBe(2)
  })
})

describe('computeBackToBackRunBySlot', () => {
  const runOf = (schedule: ScheduleSlot[], id: string) => {
    const runs = computeBackToBackRunBySlot(schedule, [id])
    return Object.fromEntries(runs[toPlayerId(id)])
  }

  it('gives the run length to every slot of the run and omits a lone game', () => {
    const schedule = [1, 2, 4, 6, 7].map((slot) =>
      game(slot, 0, ['p1', 'p2'], ['p3', 'p4']),
    )

    expect(runOf(schedule, 'p1')).toEqual({ 1: 2, 2: 2, 6: 2, 7: 2 })
    expect(runOf(schedule, 'p1')).not.toHaveProperty('4')
  })

  it('marks every slot of a three-game run with the run length', () => {
    const schedule = [0, 1, 2].map((slot) => game(slot, 0, ['p9', 'p10'], ['p11', 'p12']))

    expect(runOf(schedule, 'p9')).toEqual({ 0: 3, 1: 3, 2: 3 })
  })

  it('returns an empty run map for a player with no games', () => {
    const schedule = [game(0, 0, ['p1', 'p2'], ['p3', 'p4'])]

    expect(runOf(schedule, 'p11')).toEqual({})
  })
})