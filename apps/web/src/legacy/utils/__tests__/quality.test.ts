import { describe, expect, it } from 'vitest'
import { computeQuality, isGoodQuality, qualityScore } from '../quality'
import { toPlayerId } from '../../types'
import type { GeneratorResult } from '../../generator'
import type { MatchConstraint, Player, ScheduleSlot, Tier } from '../../types'

const player = (id: string, tier: Tier = 4): Player => ({
  id: toPlayerId(id),
  name: id,
  gender: 'M',
  tier,
})

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

const playerMapOf = (...players: Player[]) =>
  new Map(players.map((p) => [p.id as string, p]))

const result = (schedule: ScheduleSlot[], overrides: Partial<GeneratorResult> = {}): GeneratorResult => ({
  schedule,
  playCount: {},
  sitCount: {},
  partnerWith: {},
  facedBy: {},
  unplacedFixMatches: [],
  ...overrides,
})

const oneGame = [game(0, 0, ['p1', 'p2'], ['p3', 'p4'])]

describe('computeQuality', () => {
  it('returns null for an empty roster and for an empty schedule', () => {
    expect(computeQuality(result(oneGame), new Map(), [])).toBeNull()
    expect(computeQuality(result([]), playerMapOf(player('p1')), [])).toBeNull()
  })

  it('flags an uneven game only once the tier gap reaches 4', () => {
    const wide = playerMapOf(player('p1', 2), player('p2', 2), player('p3', 4), player('p4', 4))
    const narrow = playerMapOf(player('p1', 2), player('p2', 2), player('p3', 4), player('p4', 3))

    expect(computeQuality(result(oneGame), wide, [])?.unevenGames).toBe(1)
    expect(computeQuality(result(oneGame), narrow, [])?.unevenGames).toBe(0)
  })

  it('counts a repeated partner pair once per pair, not once per game', () => {
    const players = playerMapOf(player('p1'), player('p2'), player('p3'), player('p4'))
    const partnerWith = {
      [toPlayerId('p1')]: { [toPlayerId('p2')]: 3 },
      [toPlayerId('p2')]: { [toPlayerId('p1')]: 3 },
    }

    const quality = computeQuality(result(oneGame, { partnerWith }), players, [])

    expect(quality?.repeatedPairs).toBe(1)
  })

  it('reports a fixed pair as excluded instead of repeated', () => {
    const players = playerMapOf(player('p1'), player('p2'), player('p3'), player('p4'))
    const partnerWith = {
      [toPlayerId('p1')]: { [toPlayerId('p2')]: 2 },
      [toPlayerId('p2')]: { [toPlayerId('p1')]: 2 },
    }
    const fixedPair: MatchConstraint = {
      id: 'fix-1',
      slots: [toPlayerId('p1'), toPlayerId('p2'), toPlayerId(''), toPlayerId('')],
      mode: 'flexible',
    }

    const quality = computeQuality(result(oneGame, { partnerWith }), players, [fixedPair])

    expect(quality?.repeatedPairs).toBe(0)
    expect(quality?.excludedPairs).toBe(1)
  })

  it('reports a fixed opponent clash as excluded instead of repeated', () => {
    const players = playerMapOf(player('p1'), player('p2'), player('p3'), player('p4'))
    const facedBy = {
      [toPlayerId('p1')]: { [toPlayerId('p3')]: 3 },
      [toPlayerId('p3')]: { [toPlayerId('p1')]: 3 },
    }
    const fixedGame: MatchConstraint = {
      id: 'fix-1',
      slots: [toPlayerId('p1'), toPlayerId('p2'), toPlayerId('p3'), toPlayerId('p4')],
      mode: 'flexible',
    }

    const quality = computeQuality(result(oneGame, { facedBy }), players, [fixedGame])

    // Of the three meetings, one was forced by the constraint and is blamed on
    // it; the two that remain are still a repetition the generator caused.
    expect(quality?.excludedOpponents).toBe(1)
    expect(quality?.repeatedOpponents).toBe(1)
  })

  it('counts the players shared by two consecutive slots and their forced overlap', () => {
    // 7 players across two single-court slots: p1 is the only repeat, and one
    // repeat is unavoidable because 8 slots need 4 more players than exist.
    const players = playerMapOf(
      player('p1'),
      player('p2'),
      player('p3'),
      player('p4'),
      player('p5'),
      player('p6'),
      player('p7'),
    )
    const schedule = [
      game(0, 0, ['p1', 'p2'], ['p3', 'p4']),
      game(1, 0, ['p1', 'p5'], ['p6', 'p7']),
    ]

    const quality = computeQuality(result(schedule), players, [])

    expect(quality?.backToBackCount).toBe(1)
    expect(quality?.backToBackFloor).toBe(1)
  })
})

describe('qualityScore', () => {
  it('weights spread, imbalance and repeated pairs', () => {
    const players = playerMapOf(player('p1', 4), player('p2', 4), player('p3', 6), player('p4', 6))
    const imbalanced = result(oneGame, {
      playCount: { p1: 3, p2: 3, p3: 1, p4: 1 },
      partnerWith: {
        [toPlayerId('p1')]: { [toPlayerId('p2')]: 2 },
        [toPlayerId('p2')]: { [toPlayerId('p1')]: 2 },
      },
    })

    // spread 2 (20) + one uneven game (2) + one repeated pair (3)
    expect(qualityScore(imbalanced, players, [])).toBe(25)
  })

  it('returns Infinity when there is nothing to score', () => {
    expect(qualityScore(result([]), new Map(), [])).toBe(Infinity)
  })
})

describe('isGoodQuality', () => {
  it('accepts a balanced schedule', () => {
    const players = playerMapOf(player('p1'), player('p2'), player('p3'), player('p4'))
    const balanced = result(oneGame, { playCount: { p1: 2, p2: 2, p3: 1, p4: 1 } })

    expect(isGoodQuality(balanced, players, [])).toBe(true)
  })

  it('rejects a spread out of balance and a schedule with nothing in it', () => {
    const players = playerMapOf(player('p1'), player('p2'), player('p3'), player('p4'))
    const stretched = result(oneGame, { playCount: { p1: 3, p2: 3, p3: 1, p4: 1 } })

    expect(isGoodQuality(stretched, players, [])).toBe(false)
    expect(isGoodQuality(result([]), players, [])).toBe(false)
  })
})