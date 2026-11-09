import { afterEach, describe, expect, it, vi } from 'vitest'
import { act, fireEvent, render, screen } from '@testing-library/react'
import ErrorBanner from '../ErrorBanner'

describe('ErrorBanner', () => {
  afterEach(() => {
    vi.useRealTimers()
  })

  it('does not time out a failure', () => {
    vi.useFakeTimers()
    render(<ErrorBanner message="That change was not saved." />)

    act(() => {
      vi.advanceTimersByTime(10_000)
    })

    expect(screen.getByRole('alert')).toHaveTextContent('That change was not saved.')
  })

  it('stays until dismissed and offers a retry', () => {
    const onRetry = vi.fn()
    const onDismiss = vi.fn()
    render(
      <ErrorBanner
        message="That change was not saved."
        onRetry={onRetry}
        onDismiss={onDismiss}
      />,
    )

    fireEvent.click(screen.getByRole('button', { name: 'Retry' }))
    expect(onRetry).toHaveBeenCalledTimes(1)

    fireEvent.click(screen.getByRole('button', { name: 'Dismiss' }))
    expect(onDismiss).toHaveBeenCalledTimes(1)
  })
})
