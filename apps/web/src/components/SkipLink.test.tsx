import { describe, expect, it } from 'vitest'
import { render, screen } from '@testing-library/react'
import { SkipLink } from './SkipLink'

describe('SkipLink', () => {
  it('points at the main region and reads as the way to the content', () => {
    render(<SkipLink />)

    const link = screen.getByRole('link', { name: 'Skip to content' })
    expect(link).toHaveAttribute('href', '#main')
    // Hidden until focused, then painted above the header.
    expect(link.className).toContain('sr-only')
    expect(link.className).toContain('focus:not-sr-only')
  })
})
