import { describe, expect, it } from 'vitest'
import { render, screen } from '@testing-library/react'
import { LoadingState } from './LoadingState'

describe('LoadingState', () => {
  it('names the wait for screen readers and draws the requested rows', () => {
    const { container } = render(<LoadingState label="Loading players" rows={2} />)

    expect(screen.getByRole('status')).toHaveTextContent('Loading players')
    expect(container.querySelectorAll('.animate-pulse > div')).toHaveLength(2)
  })

  it('defaults to three rows', () => {
    const { container } = render(<LoadingState label="Loading" />)

    expect(container.querySelectorAll('.animate-pulse > div')).toHaveLength(3)
  })
})
