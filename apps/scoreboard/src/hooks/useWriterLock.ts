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

    const controller = new AbortController()
    let release: (() => void) | null = null

    void locks
      .request(
        WRITER_LOCK,
        { ifAvailable: true, signal: controller.signal },
        lock => {
          if (!lock) {
            setIsWriter(false)
            return
          }
          setIsWriter(true)
          // Hold the lock until this document goes away.
          return new Promise<void>(resolve => {
            release = resolve
          })
        },
      )
      .catch(() => {
        // Aborted before it was granted: the effect is being torn down.
      })

    return () => {
      controller.abort()
      release?.()
    }
  }, [])

  return isWriter
}
