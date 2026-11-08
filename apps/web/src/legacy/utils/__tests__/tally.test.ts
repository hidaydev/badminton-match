import { describe, expect, it } from 'vitest'
import { computeDiff, initTallyRow, standardStandingSort, tallyMatch } from '../tally'
import type { TallyRow } from '../tally'

describe('tallyMatch', () => {
  it('lets an explicit won flag override the point comparison', () => {
    // Set-winner rule: the side that took the sets lost on total points.
    const row = initTallyRow()

    tallyMatch(row, 19, 21, true)

    expect(row).toEqual({ wins: 1, losses: 0, pointsFor: 19, pointsAgainst: 21, diff: 0 })
  })

  it('falls back to comparing points when no flag is given', () => {
    const row = initTallyRow()

    tallyMatch(row, 21, 19)
    tallyMatch(row, 15, 21)

    expect(row.wins).toBe(1)
    expect(row.losses).toBe(1)
    expect(row.pointsFor).toBe(36)
    expect(row.pointsAgainst).toBe(40)
  })
})

describe('computeDiff', () => {
  it('stores points for minus points against', () => {
    const row = initTallyRow()
    tallyMatch(row, 21, 19)
    tallyMatch(row, 15, 21)

    computeDiff(row)

    expect(row.diff).toBe(-4)
  })
})

describe('standardStandingSort', () => {
  const row = (wins: number, diff: number, pointsFor: number): TallyRow => ({
    wins,
    losses: 0,
    pointsFor,
    pointsAgainst: pointsFor - diff,
    diff,
  })

  it('orders by wins first', () => {
    const moreWins = row(2, 0, 40)
    const fewerWins = row(1, 20, 60)

    expect(standardStandingSort(moreWins, fewerWins)).toBeLessThan(0)
    expect(standardStandingSort(fewerWins, moreWins)).toBeGreaterThan(0)
  })

  it('breaks a wins tie on point difference', () => {
    const better = row(2, 8, 40)
    const worse = row(2, 3, 40)

    expect(standardStandingSort(better, worse)).toBeLessThan(0)
  })

  it('breaks a wins and diff tie on points for', () => {
    const higher = row(2, 5, 60)
    const lower = row(2, 5, 40)

    expect(standardStandingSort(higher, lower)).toBeLessThan(0)
  })

  it('returns 0 for a full tie', () => {
    expect(standardStandingSort(row(2, 5, 40), row(2, 5, 40))).toBe(0)
  })
})