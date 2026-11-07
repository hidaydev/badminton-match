import { describe, expect, it, vi } from 'vitest'
import { fireEvent, render, screen } from '@testing-library/react'
import { Overlay } from './Overlay'

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
})