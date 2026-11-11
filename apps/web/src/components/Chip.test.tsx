import { render, screen } from '@testing-library/react'
import { describe, expect, it, vi } from 'vitest'
import { Chip } from './Chip'

describe('Chip', () => {
  it('is an unpressed toggle by default', () => {
    render(<Chip onClick={() => undefined}>Tier A</Chip>)
    const chip = screen.getByRole('button', { name: 'Tier A' })

    expect(chip).toHaveAttribute('aria-pressed', 'false')
    expect(chip).toHaveAttribute('type', 'button')
    expect(chip.className).toContain('min-h-11')
  })

  it('reports the selected state to assistive tech and to the accent outline', () => {
    render(<Chip selected>Tier A</Chip>)
    const chip = screen.getByRole('button', { name: 'Tier A' })

    expect(chip).toHaveAttribute('aria-pressed', 'true')
    expect(chip.className).toContain('aria-pressed:border-accent')
    expect(chip.className).toContain('aria-pressed:text-accent')
  })

  it('carries the hover, focus, active and disabled recipes', () => {
    render(<Chip>Filter</Chip>)
    const chip = screen.getByRole('button', { name: 'Filter' })

    expect(chip.className).toContain('hover:bg-elevated')
    expect(chip.className).toContain('focus-ring')
    expect(chip.className).toContain('active:scale-[0.99]')
    expect(chip.className).toContain('disabled-dim')
  })

  it('blocks a second press while disabled or loading and keeps the label', () => {
    const onClick = vi.fn()
    render(
      <>
        <Chip disabled onClick={onClick}>
          Female
        </Chip>
        <Chip loading onClick={onClick}>
          Male
        </Chip>
      </>,
    )
    const disabled = screen.getByRole('button', { name: 'Female' })
    const loading = screen.getByRole('button', { name: 'Male' })

    expect(disabled).toBeDisabled()
    expect(loading).toBeDisabled()
    expect(loading).toHaveAttribute('aria-busy', 'true')
  })

  it('narrows the padding for the sm size and passes caller props through', () => {
    render(
      <Chip size="sm" className="ml-1" data-testid="chip">
        A+
      </Chip>,
    )
    const chip = screen.getByTestId('chip')

    expect(chip.className).toContain('px-2.5')
    expect(chip.className).toContain('ml-1')
  })
})
