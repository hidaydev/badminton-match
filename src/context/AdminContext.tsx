// src/context/AdminContext.tsx — state admin (token di sessionStorage).
import { createContext, useContext, useState, useCallback, type ReactNode } from 'react'
import { setAdminToken } from '../queries/endpoints'

const STORAGE_KEY = 'majadu_admin_token'

interface AdminContextValue {
  isAdmin: boolean
  login: (token: string) => boolean
  logout: () => void
}

const AdminContext = createContext<AdminContextValue>({
  isAdmin: false,
  login: () => false,
  logout: () => {},
})

export function AdminProvider({ children }: { children: ReactNode }) {
  const [token, setToken] = useState<string>(() => sessionStorage.getItem(STORAGE_KEY) ?? '')

  const login = useCallback((t: string) => {
    const trimmed = t.trim()
    if (!trimmed) return false
    sessionStorage.setItem(STORAGE_KEY, trimmed)
    setAdminToken(trimmed)
    setToken(trimmed)
    return true
  }, [])

  const logout = useCallback(() => {
    sessionStorage.removeItem(STORAGE_KEY)
    setAdminToken('')
    setToken('')
  }, [])

  return (
    <AdminContext.Provider value={{ isAdmin: !!token, login, logout }}>
      {children}
    </AdminContext.Provider>
  )
}

// eslint-disable-next-line react-refresh/only-export-components
export function useAdmin() {
  return useContext(AdminContext)
}
