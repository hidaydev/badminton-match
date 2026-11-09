import { describe, expect, it, vi } from 'vitest'
import { act, fireEvent, render, screen } from '@testing-library/react'
import { ClientOutdatedBanner } from './ClientOutdatedBanner'
import { CLIENT_OUTDATED_EVENT } from '../auth/api'

describe('ClientOutdatedBanner', () => {
  it('renders nothing until the transport reports an outdated client', () => {
    const { container } = render(<ClientOutdatedBanner message="Out of date" actionLabel="Reload" />)
    expect(container).toBeEmptyDOMElement()

    act(() => {
      window.dispatchEvent(new Event(CLIENT_OUTDATED_EVENT))
    })

    expect(screen.getByRole('alert')).toHaveTextContent('Out of date')
  })

  it('reloads the tab from the action', () => {
    const original = window.location
    const reload = vi.fn()
    Object.defineProperty(window, 'location', {
      configurable: true,
      value: { ...original, reload },
    })

    render(<ClientOutdatedBanner message="Out of date" actionLabel="Reload" />)
    act(() => {
      window.dispatchEvent(new Event(CLIENT_OUTDATED_EVENT))
    })
    fireEvent.click(screen.getByRole('button', { name: 'Reload' }))

    expect(reload).toHaveBeenCalledTimes(1)
    Object.defineProperty(window, 'location', { configurable: true, value: original })
  })
})
