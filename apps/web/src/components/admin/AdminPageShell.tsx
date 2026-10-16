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
      const result = await fn()
      if (result === false) return
      flash(okLabel)
      refresh?.()
    } catch (e) {
      flash(undefined, e instanceof Error ? e.message : 'Failed')
    }
  }, [flash])

  if (!isAdmin) {
    return (
      <div className="flex flex-col gap-3 py-10">
        <p className="text-fg-dim text-sm">Admin mode inactive.</p>
        <button onClick={() => navigate('/')} className="text-accent text-sm text-left">Back to home</button>
      </div>
    )
  }

  return (
    <div className="flex flex-col gap-4 pb-20">
      {/* Header */}
      <div className="flex items-center justify-between px-3.5 py-2.5 rounded-xl bg-surface border border-border-subtle shadow-xs">
        <div className="flex items-center gap-2">
          <span className="text-sm font-bold text-fg leading-tight">{t('admin.title')}</span>
          <span className="text-[10px] font-mono px-1.5 py-0.2 rounded bg-accent/15 border border-accent/30 text-accent font-bold">ROOT</span>
        </div>
        <div className="flex items-center gap-3">
          <button
            onClick={() => navigate('/')}
            className="text-xs text-fg-dim hover:text-fg transition-colors cursor-pointer"
          >
            Home
          </button>
          <button
            onClick={logout}
            className="text-xs text-error/80 hover:text-error transition-colors font-medium cursor-pointer"
          >
            {t('admin.logout')}
          </button>
        </div>
      </div>

      {error && <p className="text-error text-xs bg-error/10 border border-error/30 rounded-lg px-3 py-2 font-medium">{error}</p>}
      {okMsg && <p className="text-success text-xs bg-success/10 border border-success/30 rounded-lg px-3 py-2 font-medium">{okMsg}</p>}

      {children({ run, error, okMsg })}
    </div>
  )
}
