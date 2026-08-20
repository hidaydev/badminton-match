// src/components/admin/AdminPageShell.tsx — Shared layout untuk semua admin pages.
// Auth guard + banner + flash messages + run() helper.
import { useState, useCallback } from 'react'
import { useNavigate } from 'react-router-dom'
import { useAdmin } from '../../context/AdminContext'
import { t } from '../../i18n'

interface AdminPageShellProps {
  children: (ctx: {
    run: (fn: () => Promise<unknown>, okLabel: string, refresh?: () => void) => Promise<void>
    error: string | null
    okMsg: string | null
  }) => React.ReactNode
}

// Module-level timer storage — safe because only one admin page is mounted at a time.
let flashTimer: ReturnType<typeof setTimeout> | null = null

function clearFlashTimer() {
  if (flashTimer) { clearTimeout(flashTimer); flashTimer = null }
}

export default function AdminPageShell({ children }: AdminPageShellProps) {
  const { isAdmin, logout } = useAdmin()
  const navigate = useNavigate()
  const [error, setError] = useState<string | null>(null)
  const [okMsg, setOkMsg] = useState<string | null>(null)

  const flash = useCallback((ok?: string, err?: string) => {
    clearFlashTimer()
    setOkMsg(ok ?? null)
    setError(err ?? null)
    flashTimer = setTimeout(() => { setOkMsg(null); setError(null) }, 4000)
  }, [])

  const run = useCallback(async (fn: () => Promise<unknown>, okLabel: string, refresh?: () => void) => {
    setError(null)
    try {
      await fn()
      flash(okLabel)
      refresh?.()
    } catch (e) {
      flash(undefined, e instanceof Error ? e.message : 'Failed')
    }
  }, [flash])

  if (!isAdmin) {
    return (
      <div className="flex flex-col gap-3">
        <p className="text-amber-300/80 text-sm">Admin mode inactive.</p>
        <button onClick={() => navigate('/')} className="text-accent text-sm">Back to home</button>
      </div>
    )
  }

  return (
    <div className="flex flex-col gap-5">
      {/* Banner pembeda */}
      <div className="flex items-center justify-between px-4 py-3 rounded-lg bg-amber-950/30 border border-amber-800/60">
        <div className="flex flex-col">
          <p className="text-sm font-bold text-amber-200">{t('admin.title')}</p>
          <p className="text-[10px] font-mono text-amber-300/60 uppercase tracking-wider">{t('admin.subtitle')}</p>
        </div>
        <button onClick={logout} className="text-xs font-mono text-fg-dim hover:text-red-400 transition-colors">{t('admin.logout')}</button>
      </div>

      {error && <p className="text-red-400 text-xs bg-red-950/30 border border-red-800/60 rounded-lg px-3 py-2">{error}</p>}
      {okMsg && <p className="text-emerald-400 text-xs bg-emerald-950/30 border border-emerald-800/60 rounded-lg px-3 py-2">{okMsg}</p>}

      {children({ run, error, okMsg })}
    </div>
  )
}
