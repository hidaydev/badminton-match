import { createContext, useContext } from 'react'
import type { Membership, SessionUser } from './api'

export type AuthContextValue = {
  user: SessionUser | null
  memberships: Membership[]
  loading: boolean
  /** True while the login request is in flight (button feedback only). */
  loggingIn: boolean
  login: () => Promise<void>
  logout: () => Promise<void>
}

export const AuthContext = createContext<AuthContextValue | null>(null)

export function useAuth(): AuthContextValue {
  const value = useContext(AuthContext)
  if (value === null) throw new Error('useAuth must be used inside AuthProvider')
  return value
}
