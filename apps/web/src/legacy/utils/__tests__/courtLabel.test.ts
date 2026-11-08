import { describe, expect, it } from 'vitest'
import { courtLabel } from '../courtLabel'

describe('courtLabel', () => {
  it('prefers the configured name', () => {
    expect(courtLabel(['Lapangan A', 'Lapangan B'], 1)).toBe('Lapangan B')
  })

  it('falls back to letters when the name is missing or empty', () => {
    expect(courtLabel(undefined, 0)).toBe('A')
    expect(courtLabel([], 2)).toBe('C')
    expect(courtLabel(['Ada', ''], 1)).toBe('B')
  })

  it('keeps the last letter for index 25 and switches to numbers after it', () => {
    expect(courtLabel(undefined, 25)).toBe('Z')
    expect(courtLabel(undefined, 26)).toBe('27')
  })
})