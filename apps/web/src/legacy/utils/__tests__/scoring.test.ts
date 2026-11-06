import { describe, expect, it } from 'vitest'
import { matchComplete, setsWon, validateSet, validateSets, winnerOf } from '../scoring'
import type { SessionScoring, SetScore } from '../../types'

// The table modules/session/tests/scoring_test.nim enforces on the server. If
// these disagree, the editor offers a set the API will refuse.
const majadu: SessionScoring = {
  preset: 'majadu30', label: 'MAJADU 30', gamesToWin: 1,
  pointsToWin: 30, winBy: 1, deuceAt: null, maxPoints: 30, changeEndsAt: 15,
}
const classic: SessionScoring = {
  preset: 'classic21', label: 'Classic BO3 21', gamesToWin: 2,
  pointsToWin: 21, winBy: 2, deuceAt: 20, maxPoints: 30, changeEndsAt: 11,
}
const bwf: SessionScoring = {
  preset: 'bwf15', label: 'New BWF BO3 15', gamesToWin: 2,
  pointsToWin: 15, winBy: 2, deuceAt: 14, maxPoints: 21, changeEndsAt: 8,
}

const set = (a: number, b: number): SetScore => ({ a, b })

describe('validateSet', () => {
  it('accepts a MAJADU 30 game at the cap', () => {
    expect(validateSet(majadu, set(30, 29), 1)).toBeNull()
    expect(validateSet(majadu, set(30, 0), 1)).toBeNull()
  })

  it('rejects a score below the target and above the cap', () => {
    expect(validateSet(majadu, set(29, 28), 1)).toContain('must reach 30')
    expect(validateSet(majadu, set(31, 29), 1)).toContain('cap')
  })

  it('needs a two-point margin at deuce', () => {
    expect(validateSet(classic, set(21, 19), 1)).toBeNull()
    expect(validateSet(classic, set(21, 20), 1)).toContain('win by 2')
    expect(validateSet(classic, set(22, 20), 1)).toBeNull()
    expect(validateSet(classic, set(30, 29), 2)).toBeNull() // the cap decides
  })

  it('applies the 15-point format', () => {
    expect(validateSet(bwf, set(15, 14), 1)).toContain('win by 2')
    expect(validateSet(bwf, set(16, 14), 1)).toBeNull()
    expect(validateSet(bwf, set(22, 20), 1)).toContain('cap')
  })

  it('rejects ties and out-of-range scores', () => {
    expect(validateSet(classic, set(15, 15), 1)).toContain('equal')
    expect(validateSet(classic, set(-1, 5), 1)).toContain('negative')
    expect(validateSet(classic, set(100, 5), 3)).toContain('Set 3')
  })
})

describe('validateSets', () => {
  it('stops once a side reaches gamesToWin', () => {
    expect(validateSets(classic, [set(21, 19), set(21, 19)]).error).toBeNull()
    const extra = validateSets(classic, [set(21, 19), set(21, 19), set(21, 19)])
    expect(extra.error).toContain('already won')
    expect(extra.set).toBe(3)
  })

  it('refuses more sets than the format can hold', () => {
    expect(validateSets(majadu, [set(30, 28), set(30, 28)]).error).toContain('Too many')
  })

  it('names the offending set', () => {
    const verdict = validateSets(classic, [set(21, 19), set(21, 20)])
    expect(verdict.error).toContain('Set 2')
    expect(verdict.set).toBe(2)
  })
})

describe('result helpers', () => {
  it('counts sets, not points', () => {
    const sets = [set(21, 19), set(19, 21), set(21, 17)]
    expect(setsWon(sets)).toEqual({ a: 2, b: 1 })
    expect(matchComplete(classic, sets)).toBe(true)
    expect(winnerOf(classic, sets)).toBe('A')
  })

  it('treats a partial match as unfinished', () => {
    expect(winnerOf(classic, [set(21, 19), set(19, 21)])).toBeNull()
    expect(winnerOf(majadu, [set(28, 30)])).toBe('B')
  })
})