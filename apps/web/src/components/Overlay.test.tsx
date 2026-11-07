import { afterEach, describe, expect, it, vi } from 'vitest'
import { fireEvent, render, screen } from '@testing-library/react'
import { Overlay } from './Overlay'

afterEach(() => {
  vi.unstubAllGlobals()
})

type OverlayOverrides = {
  description?: string
  dismissible?: boolean
  footer?: string
  labelledBy?: string
}

function renderOverlay(overrides: OverlayOverrides = {}) {
  const onClose = vi.fn()
  const view = render(
    <Overlay onClose={onClose} title="Sheet title" {...overrides}>
      <button>inside</button>
    </Overlay>,
  )
  return { onClose, ...view }
}

function scrimFor(dialog: HTMLElement): HTMLElement {
  const scrim = dialog.parentElement
  if (scrim === null) throw new Error('dialog has no scrim')
  return scrim
}

describe('Overlay', () => {
  it('closes on Escape', () => {
    const { onClose } = renderOverlay()
    fireEvent.keyDown(window, { key: 'Escape' })
    expect(onClose).toHaveBeenCalledTimes(1)
  })

  it('closes on a scrim tap that starts on the scrim', () => {
    const { onClose } = renderOverlay()
    const scrim = scrimFor(screen.getByRole('dialog', { name: 'Sheet title' }))
    fireEvent.pointerDown(scrim)
    fireEvent.click(scrim)
    expect(onClose).toHaveBeenCalledTimes(1)
  })

  it('ignores a scrim click when the press started inside the sheet', () => {
    const { onClose } = renderOverlay()
    const dialog = screen.getByRole('dialog', { name: 'Sheet title' })
    fireEvent.pointerDown(screen.getByRole('button', { name: 'inside' }))
    fireEvent.click(scrimFor(dialog))
    expect(onClose).not.toHaveBeenCalled()
  })

  it('ignores Escape and the scrim and renders no close button when not dismissible', () => {
    const { onClose } = renderOverlay({ dismissible: false })
    const dialog = screen.getByRole('dialog', { name: 'Sheet title' })
    fireEvent.keyDown(window, { key: 'Escape' })
    fireEvent.pointerDown(scrimFor(dialog))
    fireEvent.click(scrimFor(dialog))
    expect(onClose).not.toHaveBeenCalled()
    expect(screen.queryByRole('button', { name: 'Close' })).toBeNull()
  })

  it('locks the body and restores its style after unmount', () => {
    const { unmount } = renderOverlay()
    expect(document.body.style.position).toBe('fixed')
    expect(document.body.style.overflow).toBe('hidden')
    unmount()
    expect(document.body.style.position).toBe('')
    expect(document.body.style.overflow).toBe('')
  })

  it('labels the dialog from the caller heading when labelledBy is set', () => {
    renderOverlay({ labelledBy: 'custom-heading' })
    const dialog = screen.getByRole('dialog')
    expect(dialog.getAttribute('aria-labelledby')).toBe('custom-heading')
    expect(screen.queryByRole('heading', { name: 'Sheet title' })).toBeNull()
  })

  it('restores the scroll position when two overlays close out of order', () => {
    const scrollTo = vi.spyOn(window, 'scrollTo').mockImplementation(() => {})
    vi.stubGlobal('scrollY', 420)
    const bottom = render(
      <Overlay onClose={() => {}} title="Bottom">
        <button>bottom inside</button>
      </Overlay>,
    )
    const top = render(
      <Overlay onClose={() => {}} title="Top">
        <button>top inside</button>
      </Overlay>,
    )
    expect(document.body.style.top).toBe('-420px')
    // Closing the top overlay keeps the lock: the bottom one is still open.
    top.unmount()
    expect(document.body.style.position).toBe('fixed')
    expect(document.body.style.top).toBe('-420px')
    expect(scrollTo).not.toHaveBeenCalled()
    bottom.unmount()
    expect(document.body.style.position).toBe('')
    expect(document.body.style.top).toBe('')
    expect(scrollTo).toHaveBeenCalledWith(0, 420)
  })

  it('applies a dismissible change to Escape and the close button', () => {
    const onClose = vi.fn()
    const view = render(
      <Overlay onClose={onClose} title="Sheet title" dismissible={false}>
        <button>inside</button>
      </Overlay>,
    )
    fireEvent.keyDown(window, { key: 'Escape' })
    expect(onClose).not.toHaveBeenCalled()
    expect(screen.queryByRole('button', { name: 'Close' })).toBeNull()

    view.rerender(
      <Overlay onClose={onClose} title="Sheet title">
        <button>inside</button>
      </Overlay>,
    )
    fireEvent.keyDown(window, { key: 'Escape' })
    expect(onClose).toHaveBeenCalledTimes(1)
    fireEvent.click(screen.getByRole('button', { name: 'Close' }))
    expect(onClose).toHaveBeenCalledTimes(2)
  })

  it('moves focus back into the sheet when focusKey changes', () => {
    const view = render(
      <Overlay onClose={() => {}} title="Sheet title" focusKey="formats">
        <button>inside</button>
      </Overlay>,
    )
    const dialog = screen.getByRole('dialog', { name: 'Sheet title' })
    screen.getByRole('button', { name: 'inside' }).focus()
    expect(document.activeElement).not.toBe(dialog)

    view.rerender(
      <Overlay onClose={() => {}} title="Sheet title" focusKey="session-picker">
        <button>inside</button>
      </Overlay>,
    )
    expect(document.activeElement).toBe(dialog)
  })
})