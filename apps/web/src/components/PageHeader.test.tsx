import { describe, expect, it } from 'vitest'
import { render, screen } from '@testing-library/react'
import { PageHeader } from './PageHeader'

describe('PageHeader', () => {
  it('renders the title as the page heading and the optional subtitle', () => {
    render(<PageHeader title="Players" subtitle="Everyone in this community" />)

    expect(screen.getByRole('heading', { level: 1, name: 'Players' })).toBeInTheDocument()
    expect(screen.getByText('Everyone in this community')).toBeInTheDocument()
  })

  it('omits the subtitle when there is none', () => {
    const { container } = render(<PageHeader title="Players" />)

    expect(container.querySelectorAll('p')).toHaveLength(0)
  })
})
