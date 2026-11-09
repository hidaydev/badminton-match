import { fireEvent, render, screen } from '@testing-library/react'
import { describe, expect, it } from 'vitest'
import { Checkbox } from './Checkbox'
import { Radio } from './Radio'

describe('Checkbox', () => {
  it('renders a native checkbox tinted with the brand accent', () => {
    render(<Checkbox aria-label="Pinned" />)
    const input = screen.getByRole('checkbox', { name: 'Pinned' })
    expect(input).toHaveProperty('type', 'checkbox')
    expect(input.className).toContain('accent-accent')
  })

  it('toggles through a click', () => {
    render(<Checkbox aria-label="Pinned" />)
    const input = screen.getByRole('checkbox', { name: 'Pinned' })
    fireEvent.click(input)
    expect(input).toBeChecked()
  })
})

describe('Radio', () => {
  it('renders a native radio tinted with the brand accent', () => {
    render(<Radio aria-label="Preset" name="preset" />)
    const input = screen.getByRole('radio', { name: 'Preset' })
    expect(input).toHaveProperty('type', 'radio')
    expect(input.className).toContain('accent-accent')
  })
})
