/** How often a visible tab is allowed to ask the server for a new worker. */
export const UPDATE_CHECK_INTERVAL_MS = 15 * 60 * 1000

interface UpdateCheckOptions {
  now?: () => number
  intervalMs?: number
  doc?: Document
}

/** The slice of `ServiceWorkerRegistration` this needs. */
interface UpdatableRegistration {
  update(): Promise<unknown> | unknown
}

/**
 * A tournament tab can stay open all day, and the browser only checks for a new
 * worker on navigation or roughly daily. Check when the tab becomes visible
 * again, throttled so alt-tabbing does not hammer the server (PWA-26).
 */
export function installUpdateOnVisible(
  registration: UpdatableRegistration,
  {
    now = Date.now,
    intervalMs = UPDATE_CHECK_INTERVAL_MS,
    doc = document,
  }: UpdateCheckOptions = {},
): () => void {
  let lastCheck = now()

  const check = () => {
    if (doc.visibilityState !== 'visible') return
    const at = now()
    if (at - lastCheck < intervalMs) return
    lastCheck = at
    void registration.update()
  }

  doc.addEventListener('visibilitychange', check)
  return () => doc.removeEventListener('visibilitychange', check)
}
