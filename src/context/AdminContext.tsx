// src/context/AdminContext.tsx — state admin (token di localStorage — persist sampai logout).
import { createContext, useContext, useState, useCallback, useEffect, type ReactNode } from 'react'
import { setAdminToken, verifyAdminToken } from '../queries/endpoints'

const STORAGE_KEY = 'majadu_admin_token'

interface AdminContextValue {
  isAdmin: boolean
  login: (token: string) => Promise<boolean>
  logout: () => void
}

const AdminContext = createContext<AdminContextValue>({
  isAdmin: false,
  login: async () => false,
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

  // Verify token di localStorage saat mount — kalau token ngasal / expired → auto logout
  useEffect(() => {
    if (!token) return
    let cancelled = false
    verifyAdminToken(token).then((ok) => {
      if (!ok && !cancelled) {
        localStorage.removeItem(STORAGE_KEY)
        setAdminToken('')
        setToken('')
      }
    })
    return () => {
      cancelled = true
    }
  }, []) // run once on mount

  const login = useCallback(async (t: string) => {
    const trimmed = t.trim()
    if (!trimmed) return false
    const ok = await verifyAdminToken(trimmed)
    if (!ok) return false
    localStorage.setItem(STORAGE_KEY, trimmed)
    setToken(trimmed) // useEffect will call setAdminToken
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
