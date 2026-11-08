import { describe, expect, it } from 'vitest'
import { isPlaceholderName } from '../placeholders'

describe('isPlaceholderName', () => {
  it('accepts the placeholder patterns the API also accepts', () => {
    expect(isPlaceholderName('TBD')).toBe(true)
    expect(isPlaceholderName('free 1')).toBe(true)
    expect(isPlaceholderName('unknown')).toBe(true)
    expect(isPlaceholderName('???')).toBe(true)
  })

  it('normalises case and repeated spaces before matching', () => {
    expect(isPlaceholderName('  Free   2 ')).toBe(true)
    expect(isPlaceholderName('Belum Ada 3')).toBe(true)
  })

  it('rejects a real name and a blank one', () => {
    expect(isPlaceholderName('Arya')).toBe(false)
    expect(isPlaceholderName('free agent')).toBe(false)
    expect(isPlaceholderName('')).toBe(false)
  })
})