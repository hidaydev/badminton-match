// useFocusTrap — move focus into a dialog, keep Tab inside it, and hand focus
// back to the trigger when it closes. Escape stays with useEscapeKey so each
// dialog keeps its own close behaviour.
import { useEffect } from 'react'
import type { RefObject } from 'react'

const FOCUSABLE =
  'a[href], button:not([disabled]), input:not([disabled]), select:not([disabled]), textarea:not([disabled]), [tabindex]:not([tabindex="-1"])'

export function useFocusTrap(ref: RefObject<HTMLElement | null>, enabled = true) {
  useEffect(() => {
    if (!enabled) return
    const node = ref.current
    if (!node) return
    // A stable alias, because the closure below outlives the narrowing.
    const root: HTMLElement = node
    const previous = document.activeElement instanceof HTMLElement ? document.activeElement : null
    root.focus()

    function handleTab(event: KeyboardEvent) {
      if (event.key !== 'Tab') return
      const focusable = root.querySelectorAll<HTMLElement>(FOCUSABLE)
      if (focusable.length === 0) return
      const first = focusable[0]
      const last = focusable[focusable.length - 1]
      // The mount focus is the root itself. A sheet portalled to the end of
      // <body> has nothing focusable after it, so a plain Tab from the root
      // leaves the dialog and wraps to the page behind; both directions are
      // handled here instead of trusting document order.
      if (event.shiftKey && (document.activeElement === first || document.activeElement === root)) {
        event.preventDefault()
        last.focus()
      } else if (!event.shiftKey && (document.activeElement === last || document.activeElement === root)) {
        event.preventDefault()
        first.focus()
      }
    }

    root.addEventListener('keydown', handleTab)
    return () => {
      root.removeEventListener('keydown', handleTab)
      if (previous && document.contains(previous)) previous.focus()
    }
  }, [ref, enabled])
}