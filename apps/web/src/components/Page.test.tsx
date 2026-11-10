import { describe, expect, it } from 'vitest'
import { PAGE_COLUMN } from './Page'

describe('PAGE_COLUMN', () => {
  it('is one content width with one gutter', () => {
    expect(PAGE_COLUMN).toBe('mx-auto w-full max-w-3xl px-4')
  })
})
