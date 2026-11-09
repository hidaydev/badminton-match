import { useEffect, useState, useSyncExternalStore } from 'react'

function subscribeOnline(onChange: () => void): () => void {
  window.addEventListener('online', onChange)
  window.addEventListener('offline', onChange)
  return () => {
    window.removeEventListener('online', onChange)
    window.removeEventListener('offline', onChange)
  }
}

/** `navigator.onLine`, kept in sync with the browser's own events. */
export function useOnline(): boolean {
  return useSyncExternalStore(
    subscribeOnline,
    () => navigator.onLine,
    () => true,
  )
}

/**
 * True only once a service worker controls this page, which is the first moment
 * "works offline" is true: before that the document came from the network and
 * the precache may still be installing.
 */
export function useServiceWorkerControlled(): boolean {
  const [controlled, setControlled] = useState(
    () => typeof navigator !== 'undefined' && 'serviceWorker' in navigator && navigator.serviceWorker.controller !== null,
  )

  useEffect(() => {
    if (typeof navigator === 'undefined' || !('serviceWorker' in navigator)) return
    const container = navigator.serviceWorker
    const onChange = () => setControlled(container.controller !== null)
    onChange()
    container.addEventListener('controllerchange', onChange)
    return () => container.removeEventListener('controllerchange', onChange)
  }, [])

  return controlled
}
