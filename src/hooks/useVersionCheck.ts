import { useState, useEffect, useCallback } from 'react'

const POLL_MS = 5 * 60 * 1000 // every 5 minutes

export function useVersionCheck() {
  const [updateAvailable, setUpdateAvailable] = useState(false)

  const check = useCallback(async () => {
    try {
      const res = await fetch(`/version.json?t=${Date.now()}`, { cache: 'no-store' })
      if (!res.ok) return
      const { hash } = await res.json()
      if (hash !== __BUILD_HASH__) setUpdateAvailable(true)
    } catch {
      // network unavailable — ignore
    }
  }, [])

  useEffect(() => {
    window.addEventListener('focus', check)
    const id = setInterval(check, POLL_MS)
    return () => {
      window.removeEventListener('focus', check)
      clearInterval(id)
    }
  }, [check])

  return updateAvailable
}
