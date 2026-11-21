/** How often a visible tab is allowed to ask the server for a new worker. */
export const UPDATE_CHECK_INTERVAL_MS = 15 * 60 * 1000

interface UpdateCheckOptions {
  now?: () => number
  intervalMs?: number
  doc?: Document
  /**
   * Called when a check finds a worker already waiting to take over. The
   * plugin raises its update prompt once per waiting worker, so a banner the
   * user dismissed with "Later" would otherwise never come back for the life
   * of the tab; this is what re-raises it.
   */
  onWaiting?: () => void
}

/** The slice of `ServiceWorkerRegistration` this needs. */
interface UpdatableRegistration {
  update(): Promise<unknown> | unknown
  /** A worker installed and waiting to activate, if there is one. */
  readonly waiting?: unknown
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
    onWaiting,
  }: UpdateCheckOptions = {},
): () => void {
  let lastCheck = now()

  const check = async () => {
    if (doc.visibilityState !== 'visible') return
    const at = now()
    if (at - lastCheck < intervalMs) return
    lastCheck = at
    await registration.update()
    // `update()` resolving is when a newly installed worker becomes pending;
    // one that is already waiting means the prompt was raised before and
    // dismissed, so it is re-raised here instead of staying silent all day.
    if (onWaiting !== undefined && registration.waiting != null) onWaiting()
  }

  const listener = () => {
    check().catch(() => {
      // A failed check is not a failed tab: the next visible moment retries.
    })
  }

  doc.addEventListener('visibilitychange', listener)
  return () => doc.removeEventListener('visibilitychange', listener)
}
