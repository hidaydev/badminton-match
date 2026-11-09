import { describe, expect, it } from 'vitest'
import { render, screen } from '@testing-library/react'
import { EmptyState } from './EmptyState'

describe('EmptyState', () => {
  it('renders the title, the description and the action slot', () => {
    render(
      <EmptyState
        title="No players yet"
        description="Add the first player to start"
        action={<button type="button">Add player</button>}
      />,
    )

    expect(screen.getByText('No players yet')).toBeInTheDocument()
    expect(screen.getByText('Add the first player to start')).toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Add player' })).toBeInTheDocument()
  })

  it('can carry the page heading and an icon', () => {
    render(<EmptyState as="h1" title="Nothing here" icon={<svg aria-hidden="true" />} />)

    expect(screen.getByRole('heading', { level: 1, name: 'Nothing here' })).toBeInTheDocument()
  })

  it('omits the optional slots when they are not passed', () => {
    render(<EmptyState title="Nothing here" />)

    expect(screen.queryByRole('button')).not.toBeInTheDocument()
    expect(screen.queryByRole('img')).not.toBeInTheDocument()
  })
})
