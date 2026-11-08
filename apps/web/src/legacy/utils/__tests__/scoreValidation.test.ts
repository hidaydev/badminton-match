import { describe, expect, it } from 'vitest'
import { validateScore } from '../scoreValidation'

describe('validateScore', () => {
  it('accepts the winning scores the API accepts', () => {
    expect(validateScore(29, 24)).toBeNull()
    expect(validateScore(30, 24)).toBeNull()
  })

  it('rejects a tie', () => {
    expect(validateScore(24, 24)).toBe('Scores cannot be equal')
  })

  it('rejects a score above the cap', () => {
    expect(validateScore(100, 24)).toBe('Scores must be between 0 and 99')
    expect(validateScore(24, 100)).toBe('Scores must be between 0 and 99')
  })

  it('rejects a negative score', () => {
    expect(validateScore(-1, 0)).toBe('Scores cannot be negative')
    expect(validateScore(0, -1)).toBe('Scores cannot be negative')
  })
})