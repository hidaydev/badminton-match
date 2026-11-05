// useEscapeKey — tutup modal/overlay saat tombol Escape ditekan (a11y).
// Callback disimpan di ref supaya listener tidak re-subscribe tiap render.
// Stack global: kalau beberapa overlay aktif bersamaan, hanya overlay paling
// atas yang menangani Escape (mencegah satu tombol menutup dua modal sekaligus).
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
