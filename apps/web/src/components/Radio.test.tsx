import { describe, expect, it } from 'vitest'
import { render, screen } from '@testing-library/react'
import { Radio } from './Radio'

describe('Radio', () => {
  it('is a radio input with the shared style', () => {
    render(<Radio aria-label="Pick me" />)

    const radio = screen.getByRole('radio', { name: 'Pick me' })
    expect(radio).toHaveAttribute('type', 'radio')
    expect(radio).toHaveClass('accent-accent', 'focus-ring')
  })

  it('appends the caller classes', () => {
    render(<Radio aria-label="Pick me" className="ml-2" />)

    expect(screen.getByRole('radio', { name: 'Pick me' })).toHaveClass('ml-2')
  })

  it('forwards the checked state', () => {
    render(<Radio aria-label="Pick me" checked readOnly />)

    expect(screen.getByRole('radio', { name: 'Pick me' })).toBeChecked()
  })
})
