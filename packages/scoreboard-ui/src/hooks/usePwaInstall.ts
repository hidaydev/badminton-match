import { useEffect, useState } from 'react'

export interface BeforeInstallPromptEvent extends Event {
  prompt(): Promise<void>
  userChoice: Promise<{ outcome: 'accepted' | 'dismissed' }>
}

/**
 * iPadOS 13 and later report a desktop Safari user agent; the touch point count
 * is what still identifies the device, so the sheet is not silently missing on
 * a tablet.
 */
export function isIosDevice(
  userAgent: string = navigator.userAgent,
  maxTouchPoints: number = navigator.maxTouchPoints,
): boolean {
  if (/iphone|ipad|ipod/i.test(userAgent)) return true
  return maxTouchPoints > 1 && /Macintosh/.test(userAgent)
}

// The event can fire before the component subscribes; a module-level listener
// queues it so the sheet is not missed on a cold Android load.
let queuedPrompt: BeforeInstallPromptEvent | null = null
const promptListeners = new Set<(event: BeforeInstallPromptEvent) => void>()

if (typeof window !== 'undefined') {
  window.addEventListener('beforeinstallprompt', (event) => {
    event.preventDefault()
    queuedPrompt = event as BeforeInstallPromptEvent
    for (const listener of promptListeners) listener(queuedPrompt)
  })
}

/** Tests start from a clean queue; the app never calls this. */
export function resetInstallPromptQueue(): void {
  queuedPrompt = null
}

function standaloneNow(): boolean {
  return typeof window !== 'undefined' && window.matchMedia('(display-mode: standalone)').matches
}

export function usePwaInstall() {
  const [deferredPrompt, setDeferredPrompt] = useState<BeforeInstallPromptEvent | null>(queuedPrompt)
  const [isStandalone, setIsStandalone] = useState(standaloneNow)
  const [installed, setInstalled] = useState(false)
  const isIos = isIosDevice()

  useEffect(() => {
    const onPrompt = (event: BeforeInstallPromptEvent) => setDeferredPrompt(event)
    promptListeners.add(onPrompt)

    const onInstalled = () => {
      setInstalled(true)
      setDeferredPrompt(null)
      queuedPrompt = null
    }
    window.addEventListener('appinstalled', onInstalled)

    const query = window.matchMedia('(display-mode: standalone)')
    const onDisplayMode = () => setIsStandalone(query.matches)
    query.addEventListener?.('change', onDisplayMode)

    return () => {
      promptListeners.delete(onPrompt)
      window.removeEventListener('appinstalled', onInstalled)
      query.removeEventListener?.('change', onDisplayMode)
    }
  }, [])

  const isInstallable = !isStandalone && !installed && (isIos || deferredPrompt !== null)

  async function prompt() {
    if (!deferredPrompt) return
    await deferredPrompt.prompt()
    const { outcome } = await deferredPrompt.userChoice
    if (outcome === 'accepted') {
      setDeferredPrompt(null)
      queuedPrompt = null
    }
  }

  return { isInstallable, isIos, prompt }
}
