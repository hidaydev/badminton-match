import { describe, expect, it, vi } from 'vitest'
import { fireEvent, render, screen } from '@testing-library/react'
import { ErrorBoundary } from './ErrorBoundary'

function Broken(): never {
  throw new Error('boom')
}

describe('ErrorBoundary', () => {
  it('renders its children while nothing throws', () => {
    render(
      <ErrorBoundary>
        <span>Scoreboard</span>
      </ErrorBoundary>,
    )
    expect(screen.getByText('Scoreboard')).toBeInTheDocument()
  })

  it('replaces a crashed tree with a readable recovery screen', () => {
    const consoleError = vi.spyOn(console, 'error').mockImplementation(() => {})
    render(
      <ErrorBoundary>
        <Broken />
      </ErrorBoundary>,
    )

    expect(screen.getByRole('heading', { name: 'Scoreboard stopped' })).toBeInTheDocument()
    expect(screen.getByText(/scores stored on this device are safe/)).toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Reload' })).toBeInTheDocument()
    expect(consoleError).toHaveBeenCalled()
  })

  it('retries through the injected action', () => {
    vi.spyOn(console, 'error').mockImplementation(() => {})
    const onRetry = vi.fn()
    render(
      <ErrorBoundary onRetry={onRetry}>
        <Broken />
      </ErrorBoundary>,
    )

    fireEvent.click(screen.getByRole('button', { name: 'Reload' }))
    expect(onRetry).toHaveBeenCalledTimes(1)
  })
})
