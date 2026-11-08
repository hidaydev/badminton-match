import { describe, expect, it } from 'vitest'
import { applySlotSwap, detectSlotSwapConflict, swapKeyInList, swapKeys } from '../slotSwap'
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

const first = { slot: 0, court: 0 }
const second = { slot: 1, court: 0 }

describe('applySlotSwap', () => {
  it('exchanges the two positions and leaves the games in between alone', () => {
    const schedule = [
      game(0, 0, ['p1', 'p2'], ['p3', 'p4']),
      game(0, 1, ['p5', 'p6'], ['p7', 'p8']),
      game(1, 0, ['p1', 'p5'], ['p2', 'p6']),
    ]

    const swapped = applySlotSwap(schedule, first, second)

    expect(swapped.map((s) => [s.slot, s.court])).toEqual([[1, 0], [0, 1], [0, 0]])
    expect(swapped[0].teamA).toEqual(schedule[0].teamA)
    expect(swapped[1]).toBe(schedule[1])
    expect(schedule[0].slot).toBe(0)
    expect(schedule[2].slot).toBe(1)
  })
})

describe('swapKeys', () => {
  it('returns an empty map for an empty map', () => {
    expect(swapKeys({}, first, second)).toEqual({})
  })

  it('moves both values and leaves every other key in place, without mutating the input', () => {
    const input = { '0-0': 'a', '1-0': 'b', '2-0': 'c' }

    const output = swapKeys(input, first, second)

    expect(output).toEqual({ '1-0': 'a', '0-0': 'b', '2-0': 'c' })
    expect(input).toEqual({ '0-0': 'a', '1-0': 'b', '2-0': 'c' })
    expect(output).not.toBe(input)
  })

  it('moves a value even when only one of the two keys is present', () => {
    expect(swapKeys({ '0-0': 'a' }, first, second)).toEqual({ '1-0': 'a' })
    expect(swapKeys({ '1-0': 'b' }, first, second)).toEqual({ '0-0': 'b' })
  })
})

describe('swapKeyInList', () => {
  it('maps whichever of the two keys is present and leaves other keys alone', () => {
    expect(swapKeyInList(['0-0', '2-0'], first, second)).toEqual(['1-0', '2-0'])
    expect(swapKeyInList(['2-0'], first, second)).toEqual(['2-0'])
    const input = ['0-0', '1-0']
    const output = swapKeyInList(input, first, second)
    expect(output).toEqual(['1-0', '0-0'])
    expect(input).toEqual(['0-0', '1-0'])
  })
})

describe('detectSlotSwapConflict', () => {
  it('returns the colliding player id, not a boolean', () => {
    // Moving the slot 1 game up to slot 0 would put p9 on court 0 while p9 is
    // already playing court 1 in that slot.
    const schedule = [
      game(0, 0, ['p1', 'p2'], ['p3', 'p4']),
      game(0, 1, ['p9', 'p6'], ['p7', 'p8']),
      game(1, 0, ['p1', 'p9'], ['p10', 'p11']),
    ]

    const conflict = detectSlotSwapConflict(schedule, first, second)

    expect(conflict).toBe('p9')
  })

  it('checks the destination slot of the first game as well', () => {
    // The game moving down to slot 1 would meet p2 already playing court 1.
    const schedule = [
      game(0, 0, ['p1', 'p2'], ['p3', 'p4']),
      game(0, 1, ['p5', 'p6'], ['p7', 'p8']),
      game(1, 0, ['p5', 'p9'], ['p10', 'p11']),
      game(1, 1, ['p2', 'p12'], ['p13', 'p14']),
    ]

    const conflict = detectSlotSwapConflict(schedule, first, second)

    expect(conflict).toBe('p2')
  })

  it('returns null when slots simply trade places or a game is missing', () => {
    const schedule = [
      game(0, 0, ['p1', 'p2'], ['p3', 'p4']),
      game(1, 0, ['p1', 'p2'], ['p3', 'p4']),
    ]

    expect(detectSlotSwapConflict(schedule, first, second)).toBeNull()
    expect(detectSlotSwapConflict(schedule, { slot: 9, court: 0 }, second)).toBeNull()
  })
})