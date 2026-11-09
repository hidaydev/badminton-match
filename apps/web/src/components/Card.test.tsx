import { describe, expect, it } from 'vitest'
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

  it('passes through the remaining div props', () => {
    render(
      <Card role="group" aria-label="Danger">
        Body
      </Card>,
    )

    expect(screen.getByRole('group', { name: 'Danger' })).toBeInTheDocument()
  })
})
