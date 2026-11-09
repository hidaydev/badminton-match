// src/components/admin/AdminPageShell.tsx — Shared layout untuk semua admin pages.
// Auth guard + banner + flash messages + run() helper.
import { useState, useCallback } from 'react'
import { useNavigate } from '../../router'
import { useAdmin } from '../../context/AdminContext'
import { getSaveErrorMessage } from '../../queries/errors'
import { t } from '@/i18n'

interface AdminPageShellProps {
  /** Settings and the rating ledger belong to the community admin alone. */
  adminOnly?: boolean
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

export default function AdminPageShell({ adminOnly = false, children }: AdminPageShellProps) {
  const { isAdmin, isAdminRole } = useAdmin()
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
      flash(undefined, getSaveErrorMessage(e))
    }
  }, [flash])

  const allowed = adminOnly ? isAdminRole : isAdmin
  if (!allowed) {
    return (
      <div className="flex flex-col gap-3 py-10">
        <p className="text-fg-dim text-sm">
          {adminOnly ? 'Admin role required.' : 'Admin access required.'}
        </p>
        <button onClick={() => navigate('/')} className="inline-flex min-h-11 items-center text-accent text-sm text-left">Back to home</button>
      </div>
    )
  }

  return (
    <div className="flex flex-col gap-4 pb-20">
      {/* Header */}
      <div className="flex items-center justify-between px-3.5 py-2.5 rounded-xl bg-surface border border-border-subtle shadow-xs">
        <span className="text-sm font-bold text-fg leading-tight">{t('nav.admin')}</span>
        <button
          onClick={() => navigate('/')}
          className="inline-flex min-h-11 min-w-11 -my-2 items-center justify-center px-2 text-xs text-fg-dim hover:text-fg transition-colors cursor-pointer"
        >
          {t('legacy.home')}
        </button>
      </div>

      {error && <p className="text-error text-xs bg-error/10 border border-error/30 rounded-lg px-3 py-2 font-medium">{error}</p>}
      {okMsg && <p className="text-success text-xs bg-success/10 border border-success/30 rounded-lg px-3 py-2 font-medium">{okMsg}</p>}

      {children({ run, error, okMsg })}
    </div>
  )
}
