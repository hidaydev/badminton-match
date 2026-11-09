import { render, screen } from '@testing-library/react'
import { describe, expect, it } from 'vitest'
import { Button } from './Button'

describe('Button', () => {
  it('gives the primary action hover and press feedback', () => {
    render(<Button variant="primary">Save</Button>)
    const button = screen.getByRole('button', { name: 'Save' })
    expect(button.className).toContain('hover:')
    expect(button.className).toContain('active:')
    expect(button.className).toContain('disabled:')
  })

  it('marks a loading button busy and blocks a second press', () => {
    render(
      <Button loading onClick={() => undefined}>
        Save
      </Button>,
    )
    const button = screen.getByRole('button', { name: 'Save' })
    expect(button.getAttribute('aria-busy')).toBe('true')
    expect(button).toBeDisabled()
  })
})
