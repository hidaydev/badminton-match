import { describe, expect, it } from 'vitest'
import { bumpCoOccurrence } from '../counter'

describe('bumpCoOccurrence', () => {
  it('creates both rows and increments in both directions', () => {
    const counts: Record<string, Record<string, number>> = {}

    bumpCoOccurrence(counts, 'p1', 'p2')
    bumpCoOccurrence(counts, 'p2', 'p1')

    expect(counts).toEqual({ p1: { p2: 2 }, p2: { p1: 2 } })
  })

  it('keeps separate totals per partner', () => {
    const counts: Record<string, Record<string, number>> = {}

    bumpCoOccurrence(counts, 'p1', 'p2')
    bumpCoOccurrence(counts, 'p1', 'p3')

    expect(counts.p1).toEqual({ p2: 1, p3: 1 })
    expect(counts.p3).toEqual({ p1: 1 })
  })
})