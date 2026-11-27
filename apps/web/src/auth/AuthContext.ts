import { createContext, useContext } from 'react'
import type { Membership, SessionUser } from './api'

export type AuthContextValue = {
  user: SessionUser | null
  memberships: Membership[]
  loading: boolean
  /**
   * The bootstrap retry ladder is spent: no answer yet, and only the browser
   * coming back online or an explicit retry will try again. `loading` stays
   * true while this is set, because the shell is still deciding.
   */
  bootstrapOffline: boolean
  /** Re-run the bootstrap from its first attempt. */
  retryBootstrap: () => void
  /** True while the login request is in flight (button feedback only). */
  loggingIn: boolean
  login: () => Promise<void>
  logout: () => Promise<void>
  /**
   * Re-read the membership list after the account joined a community while the
   * tab was open (accepting an invitation), so the community shell can route
   * into it without a reload.
   */
  refreshMemberships: () => Promise<Membership[]>
}

export const AuthContext = createContext<AuthContextValue | null>(null)

export function useAuth(): AuthContextValue {
  const value = useContext(AuthContext)
  if (value === null) throw new Error('useAuth must be used inside AuthProvider')
  return value
}
