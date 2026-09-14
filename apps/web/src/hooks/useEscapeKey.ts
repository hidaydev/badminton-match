// useEscapeKey — tutup modal/overlay saat tombol Escape ditekan (a11y).
// Callback disimpan di ref supaya listener tidak re-subscribe tiap render.
import { useEffect, useRef } from 'react'

export function useEscapeKey(onEscape: () => void, enabled = true) {
  const ref = useRef(onEscape)
  useEffect(() => {
    ref.current = onEscape
  })
  useEffect(() => {
    if (!enabled) return
    const handler = (e: KeyboardEvent) => {
      if (e.key === 'Escape') ref.current()
    }
    window.addEventListener('keydown', handler)
    return () => window.removeEventListener('keydown', handler)
  }, [enabled])
}
