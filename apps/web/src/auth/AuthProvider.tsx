import { useCallback, useEffect, useMemo, useState } from 'react'
import type { ReactNode } from 'react'
import { useQueryClient } from '@tanstack/react-query'
import {
  ApiError,
  endSession,
  fetchMe,
  fetchMemberships,
  isUnauthenticated,
  startLogin,
} from './api'
import type { Membership, SessionUser } from './api'
import { SESSION_EXPIRED_EVENT } from '../api/errors'
import { BOOT_RETRY_MS } from '../api/retryPolicy'
import { useAsyncEffect } from '../hooks/useAsyncEffect'
import { AuthContext } from './AuthContext'
import type { AuthContextValue } from './AuthContext'
import { redirectTo } from './redirect'
import { clearStoreDraft } from '../legacy/store'
import { setCommunitySlug } from '../legacy/queries/endpoints'
import { settled } from '../api/settled'
import { purgePrivateImageCaches } from '../pwa/cache'

export function AuthProvider({ children }: { children: ReactNode }) {
  const queryClient = useQueryClient()
  const [user, setUser] = useState<SessionUser | null>(null)
  const [memberships, setMemberships] = useState<Membership[]>([])
  const [loading, setLoading] = useState(true)
  const [loggingIn, setLoggingIn] = useState(false)

  // One teardown for both ways a session ends. Logout and expiry must leave
  // the device in the same state: the next account must not inherit the
  // previous host's draft, cached community data or adapter slug.
  const endLocalSession = useCallback(() => {
    queryClient.clear()
    clearStoreDraft()
    // Clears the adapter's module caches (player names) as well as the slug.
    setCommunitySlug('')
    // Cache Storage is shared by every account on this origin.
    settled(purgePrivateImageCaches(), 'image cache purge failed')
  }, [queryClient])

  // The cookie can expire or be revoked while a tab stays open. Any request
  // that comes back 401 says so; treat it like a logout from the shell's angle
  // so the next screen is the login form instead of "Failed to load".
  useEffect(() => {
    const onExpired = () => {
      endLocalSession()
      setUser(null)
      setMemberships([])
    }
    window.addEventListener(SESSION_EXPIRED_EVENT, onExpired)
    return () => window.removeEventListener(SESSION_EXPIRED_EVENT, onExpired)
  }, [endLocalSession])

  useAsyncEffect((scope) => {
    let timer: ReturnType<typeof setTimeout> | null = null
    let awaitingNetwork = false

    const clearTimer = () => {
      if (timer !== null) {
        clearTimeout(timer)
        timer = null
      }
    }
    scope.onCleanup(clearTimer)

    // A dropped connection is not "signed out": the cookie may still be valid
    // and the installed app cannot sign in offline. Only a definitive answer
    // (401, 410, another 4xx) ends the session; anything else is retried while
    // the shell keeps showing its loading state (FE-49).
    const shouldRetry = (error: unknown) =>
      !(error instanceof ApiError) ||
      error.status === null ||
      error.status >= 500 ||
      error.status === 429

    const load = async (attempt: number): Promise<void> => {
      try {
        // Both requests need only the cookie, so they run together; the
        // membership answer is read after /auth/me has decided whether there is
        // a session at all.
        const membershipsPromise = fetchMemberships()
        membershipsPromise.catch(() => {})
        const session = await fetchMe()
        const joined = await membershipsPromise
        if (!scope.live) return
        setUser(session)
        setMemberships(joined)
        setLoading(false)
      } catch (error) {
        if (!scope.live) return
        if (shouldRetry(error) && attempt < BOOT_RETRY_MS.length) {
          awaitingNetwork = true
          timer = setTimeout(() => {
            timer = null
            awaitingNetwork = false
            startLoad(attempt + 1)
          }, BOOT_RETRY_MS[attempt])
          return
        }
        if (!isUnauthenticated(error)) console.error('auth bootstrap failed', error)
        setUser(null)
        setMemberships([])
        setLoading(false)
      }
    }

    // `load` reports its own failures; this catch is the guard for a throw
    // that would otherwise escape the effect or a timer.
    const startLoad = (attempt: number) => {
      settled(load(attempt), 'auth bootstrap failed')
    }

    // A browser that comes back online should re-decide immediately instead of
    // waiting for the next backoff step.
    const onOnline = () => {
      if (!awaitingNetwork) return
      clearTimer()
      awaitingNetwork = false
      startLoad(0)
    }
    window.addEventListener('online', onOnline)
    scope.onCleanup(() => window.removeEventListener('online', onOnline))

    startLoad(0)
  }, [])

  const login = useCallback(async () => {
    setLoggingIn(true)
    try {
      const authorizeUrl = await startLogin(window.location.pathname + window.location.search)
      redirectTo(authorizeUrl)
    } finally {
      setLoggingIn(false)
    }
  }, [])

  const logout = useCallback(async () => {
    await endSession()
    endLocalSession()
    setUser(null)
    setMemberships([])
  }, [endLocalSession])

  const refreshMemberships = useCallback(async () => {
    const joined = await fetchMemberships()
    setMemberships(joined)
    return joined
  }, [])

  const value = useMemo<AuthContextValue>(
    () => ({ user, memberships, loading, loggingIn, login, logout, refreshMemberships }),
    [user, memberships, loading, loggingIn, login, logout, refreshMemberships],
  )

  return <AuthContext.Provider value={value}>{children}</AuthContext.Provider>
}
