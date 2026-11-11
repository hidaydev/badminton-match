import { describe, expect, it } from 'vitest'
import { formatDiff } from './formatDiff'

describe('formatDiff', () => {
  it('signs a positive difference', () => {
    expect(formatDiff(5)).toBe('+5')
  })

  it('leaves zero unsigned', () => {
    expect(formatDiff(0)).toBe('0')
  })

  it('keeps the minus on a negative difference', () => {
    expect(formatDiff(-3)).toBe('-3')
  })
})
