import { render, screen } from '@testing-library/react'
import { describe, expect, it } from 'vitest'
import { Button, IconButton } from './Button'

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

  it('keeps the label while the spinner is showing', () => {
    render(<Button loading>Publish session</Button>)

    expect(screen.getByRole('button', { name: 'Publish session' })).toBeInTheDocument()
  })

  it('ships the ghost and dashed variants the recipe assigns', () => {
    render(
      <>
        <Button variant="ghost">Dismiss</Button>
        <Button variant="dashed">Add player</Button>
      </>,
    )
    const ghost = screen.getByRole('button', { name: 'Dismiss' })
    const dashed = screen.getByRole('button', { name: 'Add player' })

    expect(ghost.className).toContain('hover:underline')
    expect(ghost.className).not.toContain('border-border')
    expect(dashed.className).toContain('border-dashed')
  })

  it('defaults to type button so a form is never submitted by surprise', () => {
    render(<Button>Next</Button>)

    expect(screen.getByRole('button', { name: 'Next' })).toHaveAttribute('type', 'button')
  })

  it('narrows the padding for the sm size without shrinking the tap target', () => {
    render(<Button size="sm">Retry</Button>)
    const button = screen.getByRole('button', { name: 'Retry' })

    expect(button.className).toContain('px-3')
    expect(button.className).toContain('min-h-11')
  })
})

describe('IconButton', () => {
  it('takes its accessible name from the label', () => {
    render(
      <IconButton label="Remove player">
        <svg aria-hidden="true" />
      </IconButton>,
    )

    expect(screen.getByRole('button', { name: 'Remove player' })).toBeInTheDocument()
  })

  it('renders a square box and defaults to the ghost variant', () => {
    render(<IconButton label="Close">×</IconButton>)
    const button = screen.getByRole('button', { name: 'Close' })

    expect(button.className).toContain('h-11')
    expect(button.className).toContain('w-11')
    expect(button.className).toContain('text-fg-dim')
    expect(button).toHaveAttribute('type', 'button')
  })

  it('accepts a variant and the narrow size', () => {
    render(
      <IconButton label="Back" variant="secondary" size="sm">
        ←
      </IconButton>,
    )
    const button = screen.getByRole('button', { name: 'Back' })

    expect(button.className).toContain('border-border')
    expect(button.className).toContain('w-9')
  })

  it('marks a loading icon button busy and blocks a second press', () => {
    render(
      <IconButton label="Save" loading onClick={() => undefined}>
        ✓
      </IconButton>,
    )
    const button = screen.getByRole('button', { name: 'Save' })

    expect(button.getAttribute('aria-busy')).toBe('true')
    expect(button).toBeDisabled()
  })

  it('respects a disabled caller and a caller class', () => {
    render(
      <IconButton label="Remove" disabled className="ml-2">
        ×
      </IconButton>,
    )
    const button = screen.getByRole('button', { name: 'Remove' })

    expect(button).toBeDisabled()
    expect(button.className).toContain('ml-2')
  })
})
