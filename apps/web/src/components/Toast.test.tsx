import { afterEach, describe, expect, it, vi } from 'vitest'
import { act, fireEvent, render, screen } from '@testing-library/react'
import { Toast } from './Toast'

describe('Toast', () => {
  afterEach(() => {
    vi.useRealTimers()
  })

  it('announces the message as an alert', () => {
    render(<Toast message="That change was not saved." />)

    expect(screen.getByRole('alert')).toHaveTextContent('That change was not saved.')
    expect(screen.queryByRole('button')).toBeNull()
  })

  it('does not time out a failure', () => {
    vi.useFakeTimers()
    render(<Toast message="That change was not saved." />)

    act(() => {
      vi.advanceTimersByTime(10_000)
    })

    expect(screen.getByRole('alert')).toHaveTextContent('That change was not saved.')
  })

  it('stays until dismissed and offers a retry', () => {
    const onRetry = vi.fn()
    const onDismiss = vi.fn()
    render(
      <Toast
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

  it('renders a caller-supplied action between retry and dismiss', () => {
    render(
      <Toast
        message="This session changed on another device."
        action={<button type="button">Load the server version</button>}
        onDismiss={() => undefined}
      />,
    )

    const buttons = screen.getAllByRole('button').map((button) => button.textContent)
    expect(buttons).toEqual(['Load the server version', 'Dismiss'])
  })
})
