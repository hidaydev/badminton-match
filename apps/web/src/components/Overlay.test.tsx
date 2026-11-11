import { readFileSync } from 'node:fs'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { fireEvent, render, screen } from '@testing-library/react'
import { Overlay } from './Overlay'
import { Toast } from './Toast'

const css = readFileSync('src/index.css', 'utf8')

/** One rung of the z ladder, read from where it is declared. */
function rung(name: string): number {
  const match = css.match(new RegExp(`@utility ${name} \\{\\s*z-index:\\s*([0-9]+);`))
  if (match === null) throw new Error(`@utility ${name} is missing from index.css`)
  return Number(match[1])
}

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

  it('labels the dialog from the caller heading when labelledBy is set', () => {
    renderOverlay({ labelledBy: 'custom-heading' })
    const dialog = screen.getByRole('dialog')
    expect(dialog.getAttribute('aria-labelledby')).toBe('custom-heading')
    expect(screen.queryByRole('heading', { name: 'Sheet title' })).toBeNull()
  })

  it('keeps the viewport still until the last overlay closes, then restores it', () => {
    // QA-28: the escape hatch here is the observable scroll call, not the inline
    // `body.style.*` strings. An implementation that locks the page another way
    // and still restores the offset keeps this green.
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
    // Closing the top overlay keeps the lock: the bottom one is still open.
    top.unmount()
    expect(scrollTo).not.toHaveBeenCalled()
    bottom.unmount()
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

  it('keeps the sheet on the overlay rung, with the toast below it', () => {
    renderOverlay()
    render(<Toast message="Score not saved" />)

    const scrim = scrimFor(screen.getByRole('dialog', { name: 'Sheet title' }))
    // The rung is a token, not a bare number, so the ladder is readable in one
    // file and no layer can drift by accident.
    expect(scrim.classList.contains('z-overlay')).toBe(true)
    expect([...scrim.classList].filter((name) => /^z-\d+$/.test(name))).toEqual([])

    // DS-24: an alert painted over a sheet that owns the focus trap cannot be
    // focused, cannot be dismissed and covers the dialog, so a message raised
    // while a sheet is open belongs inside it as an ErrorText.
    expect(screen.getByTestId('toast').classList.contains('z-toast')).toBe(true)
    expect(rung('z-toast')).toBeLessThan(rung('z-overlay'))
  })
})
