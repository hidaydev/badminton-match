import { useEffect, useState } from 'react'

/** Web Lock held for the life of the writing tab. */
export const WRITER_LOCK = 'majadu-score-writer'

/**
 * True when this document is the one the scoreboard writes from. A second tab
 * or an installed copy gets the same storage but must not accept input, or the
 * two documents overwrite each other. When the Web Locks API is unavailable
 * (older Safari) there is nothing to coordinate with, so the app stays writable.
 */
export function useWriterLock(): boolean {
  const [isWriter, setIsWriter] = useState(true)

  useEffect(() => {
    const locks = navigator.locks
    if (!locks?.request) return

    // `LockOptions.signal` is not implemented everywhere: Chromium and WebKit
    // both reject the request with `NotSupportedError` when it is present,
    // which silently left every window writable. The lock is held by never
    // resolving the promise the callback returns, and released by resolving it.
    let release: (() => void) | null = null
    let cancelled = false

    void locks
      .request(WRITER_LOCK, { ifAvailable: true }, lock => {
        if (cancelled) return
        if (!lock) {
          setIsWriter(false)
          return
        }
        setIsWriter(true)
        return new Promise<void>(resolve => {
          release = resolve
        })
      })
      .catch(() => {
        // A browser that refuses the request leaves the app writable.
      })

    return () => {
      cancelled = true
      release?.()
    }
  }, [])

  return isWriter
}
