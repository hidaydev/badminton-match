// Admin access follows the v2 membership role. `isAdmin` means "staff" (host
// or admin) because hosts may edit sessions and tournaments; `isAdminRole`
// marks the community admin, who alone may open settings and the rating ledger.
import { createContext, useContext, useMemo, type ReactNode } from 'react'
import { useCommunity } from '../../community/CommunityContext'
import type { CommunityRole } from '../../auth/api'

interface AdminContextValue {
  /** Host or admin: session and tournament writes. */
  isAdmin: boolean
  /** Community admin only: settings and rating administration. */
  isAdminRole: boolean
  role: CommunityRole | null
}

const AdminContext = createContext<AdminContextValue>({
  isAdmin: false,
  isAdminRole: false,
  role: null,
})

export function AdminProvider({ children }: { children: ReactNode }) {
  const { current } = useCommunity()
  const role = current?.role ?? null
  const value = useMemo<AdminContextValue>(
    () => ({
      isAdmin: role === 'admin' || role === 'host',
      isAdminRole: role === 'admin',
      role,
    }),
    [role],
  )

  return <AdminContext.Provider value={value}>{children}</AdminContext.Provider>
}

// eslint-disable-next-line react-refresh/only-export-components
export function useAdmin() {
  return useContext(AdminContext)
}
