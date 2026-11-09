import { describe, expect, it, vi } from 'vitest'
import { fireEvent, render, screen } from '@testing-library/react'
import { useState } from 'react'
import { useEscapeKey } from '@majadu/scoreboard-ui'

function Overlay({ name, onEscape, enabled = true }: {
  name: string
  onEscape: () => void
  enabled?: boolean
}) {
  useEscapeKey(onEscape, enabled)
  return <div>{name}</div>
}

/** Two overlays on one screen: the stack must decide who handles Escape. */
function Stack() {
  const [calls, setCalls] = useState<string[]>([])
  return (
    <div>
      <Overlay name="first" onEscape={() => setCalls((c) => [...c, 'first'])} />
      <Overlay name="second" onEscape={() => setCalls((c) => [...c, 'second'])} />
      <output data-testid="calls">{calls.join(',')}</output>
    </div>
  )
}

const escape = () => fireEvent.keyDown(window, { key: 'Escape' })

describe('useEscapeKey', () => {
  it('calls the handler on Escape and ignores every other key', () => {
    const onEscape = vi.fn()
    render(<Overlay name="only" onEscape={onEscape} />)

    fireEvent.keyDown(window, { key: 'Enter' })
    fireEvent.keyDown(window, { key: 'Esc' })
    expect(onEscape).not.toHaveBeenCalled()

    escape()
    expect(onEscape).toHaveBeenCalledTimes(1)
  })

  it('does nothing while disabled', () => {
    const onEscape = vi.fn()
    render(<Overlay name="only" onEscape={onEscape} enabled={false} />)

    escape()
    expect(onEscape).not.toHaveBeenCalled()
  })

  it('lets only the top overlay handle Escape', () => {
    render(<Stack />)

    escape()
    expect(screen.getByTestId('calls')).toHaveTextContent('second')

    escape()
    expect(screen.getByTestId('calls')).toHaveTextContent('second,second')
  })

  it('unsubscribes on unmount so a closed overlay cannot answer', () => {
    const onEscape = vi.fn()
    const { unmount } = render(<Overlay name="only" onEscape={onEscape} />)

    unmount()
    escape()
    expect(onEscape).not.toHaveBeenCalled()
  })

  it('uses the latest callback without adding a second listener', () => {
    const first = vi.fn()
    const second = vi.fn()
    const { rerender } = render(<Overlay name="only" onEscape={first} />)

    rerender(<Overlay name="only" onEscape={second} />)
    escape()

    expect(first).not.toHaveBeenCalled()
    expect(second).toHaveBeenCalledTimes(1)
  })
})