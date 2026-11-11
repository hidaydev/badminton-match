// Overlay — the one sheet every dialog in the app builds on. It owns the scrim,
// the focus trap, Escape, the body scroll lock, the bottom safe area and the
// iOS keyboard clamp and lift, so no call site has to repeat them.
import { useEffect, useId, useRef } from 'react'
import type { MouseEvent as ReactMouseEvent, PointerEvent as ReactPointerEvent, ReactNode } from 'react'
import { useEscapeKey } from './hooks/useEscapeKey'
import { useFocusTrap } from './hooks/useFocusTrap'

export type OverlayProps = {
  /** Called by Escape, the scrim tap and the ✕ button. */
  onClose: () => void
  /** Rendered as the <h2> that labels the dialog, unless `labelledBy` is set. */
  title: ReactNode
  description?: ReactNode
  /** The only scrollable area of the sheet. */
  children: ReactNode
  footer?: ReactNode
  /** Default true. Set false while saving: no Escape, no scrim tap, no ✕. */
  dismissible?: boolean
  /** Escape hatch for a heading the caller renders inside `children`. */
  labelledBy?: string
  /**
   * Re-focus the sheet whenever this value changes. A screen switch inside the
   * sheet unmounts the button that was focused, which would drop focus to
   * `<body>` where the trap no longer catches Tab.
   */
  focusKey?: unknown
  /** Accessible name of the close button. Callers own their translations. */
  closeLabel?: string
}

const SCRIM = 'fixed inset-0 z-overlay flex items-end justify-center bg-black/60'
const SHEET =
  'relative flex w-full max-w-lg max-h-dvh flex-col overflow-hidden rounded-t-3xl border-t border-border-subtle bg-surface pb-[max(0.75rem,env(safe-area-inset-bottom))] shadow-2xl'
const HANDLE = 'mx-auto mt-3 mb-1 h-1 w-10 shrink-0 rounded-full bg-border'
const HEADER = 'shrink-0 pl-5 pr-14 pt-3 pb-2'
const BODY = 'min-h-0 flex-1 overflow-y-auto overscroll-contain px-5 pb-4'
const FOOTER = 'shrink-0 border-t border-border-subtle px-5 pt-3'
const CLOSE =
  'absolute right-2 top-2 inline-flex min-h-11 min-w-11 items-center justify-center rounded-lg text-fg-dim hover:bg-elevated focus-ring'

// One lock for the whole module: the first overlay records the scroll position,
// the last one restores it. `overflow: hidden` alone is not enough on iOS.
let lockCount = 0
let lockedScrollY = 0
let previousStyle: { overflow: string; position: string; top: string; width: string } | null = null

function lockBodyScroll(): () => void {
  if (lockCount === 0) {
    const body = document.body
    lockedScrollY = window.scrollY
    previousStyle = {
      overflow: body.style.overflow,
      position: body.style.position,
      top: body.style.top,
      width: body.style.width,
    }
    body.style.position = 'fixed'
    body.style.top = `${-lockedScrollY}px`
    body.style.width = '100%'
    body.style.overflow = 'hidden'
  }
  lockCount += 1
  return () => {
    lockCount -= 1
    if (lockCount > 0 || previousStyle === null) return
    const body = document.body
    body.style.overflow = previousStyle.overflow
    body.style.position = previousStyle.position
    body.style.top = previousStyle.top
    body.style.width = previousStyle.width
    previousStyle = null
    if (lockedScrollY !== 0) window.scrollTo(0, lockedScrollY)
  }
}

export function Overlay({
  onClose,
  title,
  description,
  children,
  footer,
  dismissible = true,
  labelledBy,
  focusKey,
  closeLabel = 'Close',
}: OverlayProps) {
  const sheetRef = useRef<HTMLDivElement>(null)
  const startedOnScrim = useRef(false)
  const titleId = useId()

  useFocusTrap(sheetRef)
  useEscapeKey(onClose, dismissible)

  useEffect(() => lockBodyScroll(), [])

  // The trap owns the mount focus; this repeats it when the caller swaps
  // screens inside the sheet and the focused button unmounts.
  useEffect(() => {
    if (focusKey === undefined) return
    sheetRef.current?.focus()
  }, [focusKey])

  // `max-h-dvh` follows the browser chrome, not the keyboard. The visual
  // viewport is the only thing that shrinks when iOS opens its keyboard, and
  // the layout viewport keeps its height, so the sheet is both clamped and
  // lifted by the part of the layout viewport the keyboard covers. This is a
  // layout approximation until it is checked on a device.
  useEffect(() => {
    const viewport = window.visualViewport
    const sheet = sheetRef.current
    if (!viewport || !sheet) return
    const clamp = () => {
      sheet.style.maxHeight = `${Math.max(viewport.height - 16, 0)}px`
      const keyboardGap = Math.max(0, window.innerHeight - viewport.height - viewport.offsetTop)
      sheet.style.marginBottom = `${keyboardGap}px`
    }
    clamp()
    viewport.addEventListener('resize', clamp)
    viewport.addEventListener('scroll', clamp)
    return () => {
      viewport.removeEventListener('resize', clamp)
      viewport.removeEventListener('scroll', clamp)
      sheet.style.maxHeight = ''
      sheet.style.marginBottom = ''
    }
  }, [])

  function handlePointerDown(event: ReactPointerEvent<HTMLDivElement>) {
    startedOnScrim.current = event.target === event.currentTarget
  }

  function handleClick(event: ReactMouseEvent<HTMLDivElement>) {
    // A drag-select that starts in the body and ends on the scrim still fires a
    // click on the root; only a gesture that began on the scrim may close.
    if (event.target !== event.currentTarget || !startedOnScrim.current) return
    if (dismissible) onClose()
  }

  return (
    <div className={SCRIM} onPointerDown={handlePointerDown} onClick={handleClick}>
      <div
        ref={sheetRef}
        role="dialog"
        aria-modal="true"
        aria-labelledby={labelledBy ?? titleId}
        tabIndex={-1}
        className={SHEET}
      >
        <div className={HANDLE} aria-hidden="true" />
        {dismissible && (
          <button type="button" className={CLOSE} aria-label={closeLabel} onClick={onClose}>
            ✕
          </button>
        )}
        {(labelledBy === undefined || description !== undefined) && (
          <div className={HEADER}>
            {labelledBy === undefined && (
              <h2 id={titleId} className="text-base font-bold text-fg">
                {title}
              </h2>
            )}
            {description !== undefined && <p className="mt-1 text-sm text-fg-dim">{description}</p>}
          </div>
        )}
        <div className={BODY}>{children}</div>
        {footer !== undefined && <div className={FOOTER}>{footer}</div>}
      </div>
    </div>
  )
}