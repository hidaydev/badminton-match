import { useCallback, useEffect, useRef, useState } from 'react'

export interface AppUpdate {
  needRefresh: boolean
  applyUpdate: () => void
  dismiss: () => void
}

// Watches the registration that vite-plugin-pwa installs in `prompt` mode.
// A worker that reaches `installed` while another one controls the page is
// waiting for SKIP_WAITING; until it gets that message the installed app stays
// on the old bundle. Without a service worker or a waiting worker this is a
// no-op, so the scoreboard keeps working in a plain browser.
export function useAppUpdate(): AppUpdate {
  const [waiting, setWaiting] = useState<ServiceWorker | null>(null)
  const [dismissed, setDismissed] = useState(false)
  const reloadPending = useRef(false)

  useEffect(() => {
    if (typeof navigator === 'undefined' || !('serviceWorker' in navigator)) return

    const container = navigator.serviceWorker
    let mounted = true
    let registration: ServiceWorkerRegistration | null = null

    const showWaiting = (worker: ServiceWorker) => {
      setWaiting(worker)
      setDismissed(false)
    }

    const onUpdateFound = () => {
      const worker = registration?.installing
      if (!worker) return
      worker.addEventListener('statechange', () => {
        if (!mounted) return
        if (worker.state === 'installed' && container.controller) showWaiting(worker)
      })
    }

    const onControllerChange = () => {
      if (reloadPending.current) window.location.reload()
    }

    container.addEventListener('controllerchange', onControllerChange)
    void container.ready.then(reg => {
      if (!mounted) return
      registration = reg
      if (reg.waiting && container.controller) showWaiting(reg.waiting)
      reg.addEventListener('updatefound', onUpdateFound)
    })

    return () => {
      mounted = false
      container.removeEventListener('controllerchange', onControllerChange)
      registration?.removeEventListener('updatefound', onUpdateFound)
    }
  }, [])

  const applyUpdate = useCallback(() => {
    if (!waiting) return
    reloadPending.current = true
    waiting.postMessage({ type: 'SKIP_WAITING' })
    setWaiting(null)
  }, [waiting])

  const dismiss = useCallback(() => {
    setDismissed(true)
    setWaiting(null)
  }, [])

  return { needRefresh: waiting !== null && !dismissed, applyUpdate, dismiss }
}
