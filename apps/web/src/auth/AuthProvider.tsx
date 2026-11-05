import { useCallback, useEffect, useMemo, useState } from 'react'
import type { ReactNode } from 'react'
import { useQueryClient } from '@tanstack/react-query'
import {
  endSession,
  fetchMe,
  fetchMemberships,
  isUnauthenticated,
  startLogin,
} from './api'
import type { Membership, SessionUser } from './api'
import { SESSION_EXPIRED_EVENT } from '../api/errors'
import { AuthContext } from './AuthContext'
import type { AuthContextValue } from './AuthContext'
import { redirectTo } from './redirect'
import { clearStoreDraft } from '../legacy/store'
import { setCommunitySlug } from '../legacy/queries/endpoints'

export function AuthProvider({ children }: { children: ReactNode }) {
  const queryClient = useQueryClient()
  const [user, setUser] = useState<SessionUser | null>(null)
  const [memberships, setMemberships] = useState<Membership[]>([])
  const [loading, setLoading] = useState(true)
  const [loggingIn, setLoggingIn] = useState(false)

  // The cookie can expire or be revoked while a tab stays open. Any request
  // that comes back 401 says so; treat it like a logout from the shell's angle
  // so the next screen is the login form instead of "Failed to load".
  useEffect(() => {
    const onExpired = () => {
      setUser(null)
      setMemberships([])
    }
    window.addEventListener(SESSION_EXPIRED_EVENT, onExpired)
    return () => window.removeEventListener(SESSION_EXPIRED_EVENT, onExpired)
  }, [])

  useEffect(() => {
    let active = true
    const load = async () => {
      try {
        const session = await fetchMe()
        const joined = await fetchMemberships()
        if (!active) return
        setUser(session)
        setMemberships(joined)
      } catch (error) {
        if (!active) return
        if (!isUnauthenticated(error)) console.error('auth bootstrap failed', error)
        setUser(null)
        setMemberships([])
      } finally {
        if (active) setLoading(false)
      }
    }
    void load()
    return () => {
      active = false
    }
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
    // The next account on this device must not inherit cached community data.
    queryClient.clear()
    clearStoreDraft()
    // Clears the adapter's module caches (player names) as well as the slug.
    setCommunitySlug('')
    setUser(null)
    setMemberships([])
  }, [queryClient])

  const value = useMemo<AuthContextValue>(
    () => ({ user, memberships, loading, loggingIn, login, logout }),
    [user, memberships, loading, loggingIn, login, logout],
  )

  return <AuthContext.Provider value={value}>{children}</AuthContext.Provider>
}
