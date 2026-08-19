// src/context/AdminContext.tsx — state admin (token di localStorage — persist sampai logout).
import { createContext, useContext, useState, useCallback, useEffect, type ReactNode } from 'react'
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
  const [token, setToken] = useState<string>(() => localStorage.getItem(STORAGE_KEY) ?? '')

  // Sinkronkan token (termasuk hasil restorasi localStorage saat reload halaman)
  // ke module endpoints. Tanpa ini: reload → isAdmin=true (dari localStorage)
  // tapi request admin TIDAK membawa Bearer → backend 401 "missing Bearer token".
  useEffect(() => {
    setAdminToken(token)
  }, [token])

  const login = useCallback((t: string) => {
    const trimmed = t.trim()
    if (!trimmed) return false
    localStorage.setItem(STORAGE_KEY, trimmed)
    setAdminToken(trimmed)
    setToken(trimmed)
    return true
  }, [])

  const logout = useCallback(() => {
    localStorage.removeItem(STORAGE_KEY)
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
