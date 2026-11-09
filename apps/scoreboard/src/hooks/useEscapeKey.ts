// useEscapeKey — close a modal or overlay when Escape is pressed (a11y).
// The callback lives in a ref so the listener does not re-subscribe on every
// render. One global stack: when several overlays are open, only the topmost
// handles Escape, so one key press cannot close two modals at once.
import { useEffect, useRef } from 'react'

const escapeStack: Array<() => void> = []

export function useEscapeKey(onEscape: () => void, enabled = true) {
  const ref = useRef(onEscape)
  useEffect(() => {
    ref.current = onEscape
  })
  useEffect(() => {
    if (!enabled) return
    const entry = () => ref.current()
    escapeStack.push(entry)
    const handler = (e: KeyboardEvent) => {
      if (e.key !== 'Escape') return
      if (escapeStack[escapeStack.length - 1] === entry) entry()
    }
    window.addEventListener('keydown', handler)
    return () => {
      window.removeEventListener('keydown', handler)
      const i = escapeStack.indexOf(entry)
      if (i >= 0) escapeStack.splice(i, 1)
    }
  }, [enabled])
}
