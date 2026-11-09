import { describe, expect, it } from 'vitest'
import { render, screen } from '@testing-library/react'
import { CollapsiblePanel } from './CollapsiblePanel'

describe('CollapsiblePanel', () => {
  it('renders the title in the summary and the body inside the disclosure', () => {
    render(
      <CollapsiblePanel title="Community settings" hint="Only admins">
        <p>Body</p>
      </CollapsiblePanel>,
    )

    expect(screen.getByText('Community settings')).toBeInTheDocument()
    expect(screen.getByText('Only admins')).toBeInTheDocument()
    expect(screen.getByText('Body').closest('details')).not.toBeNull()
  })

  it('carries the container recipe and the caller classes', () => {
    const { container } = render(
      <CollapsiblePanel title="Title" className="mt-8" id="panel" open>
        <p>Body</p>
      </CollapsiblePanel>,
    )

    const details = container.querySelector('details')
    expect(details).toHaveClass('rounded-2xl', 'border', 'border-border-subtle', 'bg-surface', 'p-4', 'mt-8')
    expect(details).toHaveAttribute('id', 'panel')
    expect(details).toHaveAttribute('open')
  })
})
