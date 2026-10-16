// src/components/admin/AdminPageShell.tsx — Shared layout untuk semua admin pages.
// Auth guard + banner + flash messages + run() helper.
import { useState, useCallback } from 'react'
import { useNavigate } from 'react-router-dom'
import { useAdmin } from '../../context/AdminContext'
import { t } from '../../i18n'
import Icon from '../Icon'

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
      // fn boleh mengembalikan false untuk menandai "tidak ada perubahan"
      // (mis. pengguna membatalkan konfirmasi kedua). Jangan tampilkan pesan
      // sukses dalam kasus itu — dulu selalu, sehingga batal pun terlihat
      // seperti berhasil.
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
      <div className="flex flex-col items-center justify-center gap-3 py-16 text-center">
        <div className="w-12 h-12 rounded-xl bg-amber-500/10 border border-amber-500/30 flex items-center justify-center text-amber-400 mb-1">
          <Icon name="admin" size={24} />
        </div>
        <p className="text-fg-dim text-sm">Admin mode inactive.</p>
        <button
          onClick={() => navigate('/')}
          className="px-4 py-2 rounded-lg bg-accent text-slate-950 font-bold text-xs active:scale-95 transition-all"
        >
          Back to home
        </button>
      </div>
    )
  }

  return (
    <div className="flex flex-col gap-4">
      {/* Admin Header Banner */}
      <div className="flex items-center justify-between px-4 py-3 rounded-xl bg-surface border border-amber-500/30 shadow-xs">
        <div className="flex items-center gap-3 min-w-0">
          <div className="w-9 h-9 rounded-lg bg-amber-500/10 border border-amber-500/30 flex items-center justify-center shrink-0 text-amber-400">
            <Icon name="admin" size={18} />
          </div>
          <div className="flex flex-col min-w-0">
            <div className="flex items-center gap-2">
              <p className="text-sm font-bold text-fg leading-tight">{t('admin.title')}</p>
              <span className="text-[9px] font-mono font-bold px-1.5 py-0.5 bg-amber-400/15 text-amber-300 border border-amber-400/30 rounded">ROOT</span>
            </div>
            <p className="text-[11px] text-fg-dim truncate">{t('admin.subtitle')}</p>
          </div>
        </div>
        <div className="flex items-center gap-2 shrink-0">
          <button
            onClick={() => navigate('/')}
            className="text-xs px-2.5 py-1.5 rounded-lg border border-border-subtle bg-elevated/70 text-fg-dim hover:text-fg active:scale-95 transition-all"
          >
            Home
          </button>
          <button
            onClick={logout}
            className="text-xs px-2.5 py-1.5 rounded-lg border border-error/30 bg-error/10 text-error hover:bg-error/20 active:scale-95 transition-all font-medium"
          >
            {t('admin.logout')}
          </button>
        </div>
      </div>

      {error && <p className="text-error text-xs bg-error/10 border border-error/30 rounded-xl px-3.5 py-2.5 font-medium">{error}</p>}
      {okMsg && <p className="text-success text-xs bg-success/10 border border-success/30 rounded-xl px-3.5 py-2.5 font-medium">{okMsg}</p>}

      {children({ run, error, okMsg })}
    </div>
  )
}
