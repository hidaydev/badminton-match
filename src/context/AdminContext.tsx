// src/context/AdminContext.tsx — state admin (token di localStorage — persist sampai logout).
import { createContext, useContext, useState, useCallback, useEffect, useRef, type ReactNode } from 'react'
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
  const [token, setToken] = useState<string>(() => {
    const t = localStorage.getItem(STORAGE_KEY) ?? ''
    // Set synchronously sebelum render pertama — mengeliminasi timing window di mana
    // child component useEffect jalan sebelum parent useEffect (React lifecycle guarantee).
    // Tanpa ini: hard reload → child admin queries terkirim tanpa Bearer header → 401 sesaat.
    setAdminToken(t)
    return t
  })

  // Sync token ke module endpoints setiap perubahan (login / logout).
  // Mount awal sudah ditangani oleh useState initializer di atas.
  useEffect(() => {
    setAdminToken(token)
  }, [token])

  // Capture initial token in a ref so the verify-on-mount effect has no external deps
  // (token sudah valid di initializer — tidak perlu re-read dari state di closure).
  const initialTokenRef = useRef(token)

  // Verify token di localStorage saat mount — kalau token ngasal / expired → auto logout.
  // Intentionally run once: pakai ref agar tidak re-verify setiap login/logout.
  useEffect(() => {
    const t = initialTokenRef.current
    if (!t) return
    let cancelled = false
    verifyAdminToken(t).then((ok) => {
      if (!ok && !cancelled) {
        localStorage.removeItem(STORAGE_KEY)
        setAdminToken('')
        setToken('')
      }
    })
    return () => {
      cancelled = true
    }
  }, []) // intentionally run once on mount

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
