import { describe, expect, it } from 'vitest'
import { validateScore } from './scoreValidation'

describe('validateScore', () => {
  it('accepts a normal win and the top of the range', () => {
    expect(validateScore(21, 18)).toBeNull()
    expect(validateScore(99, 0)).toBeNull()
    expect(validateScore(0, 99)).toBeNull()
  })

  it('refuses a tie first, even when both sides are out of range', () => {
    expect(validateScore(10, 10)).toBe('Scores cannot be equal')
    expect(validateScore(0, 0)).toBe('Scores cannot be equal')
    expect(validateScore(100, 100)).toBe('Scores cannot be equal')
  })

  it('refuses a negative side', () => {
    expect(validateScore(-1, 5)).toBe('Scores cannot be negative')
    expect(validateScore(5, -1)).toBe('Scores cannot be negative')
  })

  it('refuses a side above 99', () => {
    expect(validateScore(100, 5)).toBe('Scores must be between 0 and 99')
    expect(validateScore(5, 100)).toBe('Scores must be between 0 and 99')
  })
})