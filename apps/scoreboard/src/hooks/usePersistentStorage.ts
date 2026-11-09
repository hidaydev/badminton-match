import { useCallback, useRef, useState } from 'react'

export type PersistenceStatus =
  | 'idle'
  | 'unsupported'
  | 'persisted'
  | 'not-persisted'
  | 'error'

export interface PersistentStorage {
  status: PersistenceStatus
  requestPersistence: () => void
}

// Asks the browser to keep this origin's storage, at most once per page load.
// Older Safari has no `navigator.storage`, and the call can reject or be
// denied; none of that may block scoring, so every path only sets a status.
export function usePersistentStorage(): PersistentStorage {
  const [status, setStatus] = useState<PersistenceStatus>('idle')
  const requested = useRef(false)

  const requestPersistence = useCallback(() => {
    if (requested.current) return
    requested.current = true

    const storage: StorageManager | undefined = navigator.storage
    if (!storage || typeof storage.persist !== 'function') {
      setStatus('unsupported')
      return
    }

    storage.persist().then(
      granted => setStatus(granted ? 'persisted' : 'not-persisted'),
      () => setStatus('error'),
    )
  }, [])

  return { status, requestPersistence }
}
