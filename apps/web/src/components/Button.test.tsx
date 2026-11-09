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

  it('passes through any button attribute', () => {
    render(
      <Button id="save-player" aria-label="Save player" title="Save">
        Save
      </Button>,
    )
    const button = screen.getByRole('button', { name: 'Save player' })
    expect(button.id).toBe('save-player')
    expect(button.getAttribute('title')).toBe('Save')
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
