import { describe, expect, it, vi } from 'vitest'
import { render, screen } from '@testing-library/react'
import { Card } from './Card'

describe('Card', () => {
  it('renders the container recipe with no padding by default', () => {
    const { container } = render(<Card>Body</Card>)

    expect(container.firstElementChild).toHaveClass('rounded-2xl', 'border', 'border-border-subtle', 'bg-surface')
    expect(container.firstElementChild).not.toHaveClass('p-4')
  })

  it('applies the padding scale and the caller classes', () => {
    const { container } = render(
      <Card padding="md" className="mt-6">
        Body
      </Card>,
    )

    expect(container.firstElementChild).toHaveClass('p-4', 'mt-6')
  })

  it('applies the large padding for a section block', () => {
    const { container } = render(<Card padding="lg">Body</Card>)

    expect(container.firstElementChild).toHaveClass('p-6')
  })

  it('keeps the radius a migrated site already had', () => {
    const { container } = render(<Card radius="xl">Body</Card>)

    expect(container.firstElementChild).toHaveClass('rounded-xl')
    expect(container.firstElementChild).not.toHaveClass('rounded-2xl')
  })

  it('clips a flush card so its rows own the dividers', () => {
    const { container } = render(<Card variant="flush">Body</Card>)

    expect(container.firstElementChild).toHaveClass('overflow-hidden')
    expect(container.firstElementChild).not.toHaveClass('p-4')
  })

  it('passes through the remaining div props', () => {
    render(
      <Card role="group" aria-label="Danger">
        Body
      </Card>,
    )

    expect(screen.getByRole('group', { name: 'Danger' })).toBeInTheDocument()
  })

  it('keeps the panel recipe free of interaction styling by default', () => {
    const { container } = render(<Card>Body</Card>)

    expect(container.firstElementChild).not.toHaveClass('cursor-pointer')
  })

  it('renders the whole surface as a real button when asked', () => {
    const onClick = vi.fn()
    render(
      <Card as="button" variant="interactive" onClick={onClick}>
        Sunday draft
      </Card>,
    )
    const card = screen.getByRole('button', { name: 'Sunday draft' })

    card.click()
    expect(onClick).toHaveBeenCalledTimes(1)
    expect(card).toHaveAttribute('type', 'button')
    expect(card.className).toContain('cursor-pointer')
    expect(card.className).toContain('hover:border-border')
    expect(card.className).toContain('active:scale-[0.99]')
  })

  it('passes a submit type through an interactive card', () => {
    render(
      <Card as="button" type="submit">
        Save
      </Card>,
    )

    expect(screen.getByRole('button', { name: 'Save' })).toHaveAttribute('type', 'submit')
  })

  it('renders an interactive card as any other element', () => {
    render(
      <Card as="a" variant="interactive" href="/s/1">
        Open session
      </Card>,
    )
    const link = screen.getByRole('link', { name: 'Open session' })

    expect(link).toHaveAttribute('href', '/s/1')
    expect(link.className).toContain('cursor-pointer')
  })
})
